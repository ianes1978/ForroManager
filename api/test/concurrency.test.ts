import { beforeAll, describe, expect, it } from "vitest";
import { BASE, api, loggedInUser } from "./helpers.ts";
import { exports } from "cloudflare:workers";

let roberta: { token: string; id: number };
let franco: { token: string; id: number };

function send(method: string, path: string, token: string, body: unknown, ifMatch?: string) {
  return exports.default.fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(ifMatch ? { "If-Match": ifMatch } : {}) },
    body: JSON.stringify(body),
  });
}

beforeAll(async () => {
  roberta = await loggedInUser({ name: "Roberta" });
  franco = await loggedInUser({ name: "Franco" });
});

describe("modifiche in contemporanea", () => {
  it("non sovrascrive un socio modificato da un altro e dice chi è stato", async () => {
    const m = (await (await api("/members", { token: roberta.token, body: { firstName: "Elena", lastName: "Ricci", joinedOn: "2026-01-01" } })).json()) as {
      id: number;
      updatedAt: string;
    };
    // Entrambi aprono la scheda con la stessa versione; Franco salva per primo.
    await new Promise((r) => setTimeout(r, 1100));
    const first = await send("PATCH", `/members/${m.id}`, franco.token, { notes: "Preferisce bonifico" }, m.updatedAt);
    expect(first.status).toBe(200);
    const second = await send("PATCH", `/members/${m.id}`, roberta.token, { notes: "Altro" }, m.updatedAt);
    expect(second.status).toBe(409);
    const err = (await second.json()) as { error: { code: string; message: string } };
    expect(err.error.code).toBe("stale");
    expect(err.error.message).toBe("Franco ha modificato questi dati poco fa: ricarica e riprova.");
    // Con la versione aggiornata il salvataggio passa.
    const fresh = (await first.json()) as { updatedAt: string };
    expect((await send("PATCH", `/members/${m.id}`, roberta.token, { notes: "Altro" }, fresh.updatedAt)).status).toBe(200);
  });

  it("senza If-Match il comportamento resta quello di prima", async () => {
    const m = (await (await api("/members", { token: roberta.token, body: { firstName: "A", lastName: "B", joinedOn: "2026-01-01" } })).json()) as { id: number };
    expect((await send("PATCH", `/members/${m.id}`, franco.token, { notes: "x" })).status).toBe(200);
  });

  it("protegge anche prodotti, utenti e tariffe", async () => {
    const p = (await (await api("/products", { token: roberta.token, body: { name: "Borraccia", type: "altro", priceCents: 800 } })).json()) as { id: number; updatedAt: string };
    expect((await send("PATCH", `/products/${p.id}`, roberta.token, { priceCents: 900 }, "2000-01-01T00:00:00Z")).status).toBe(409);
    expect((await send("PATCH", `/products/${p.id}`, roberta.token, { priceCents: 900 }, p.updatedAt)).status).toBe(200);

    const users = (await (await api("/users", { token: roberta.token })).json()) as { items: { id: number; updatedAt: string }[] };
    const f = users.items.find((u) => u.id === franco.id)!;
    expect((await send("PATCH", `/users/${franco.id}`, roberta.token, { name: "Franco R." }, "2000-01-01T00:00:00Z")).status).toBe(409);
    expect((await send("PATCH", `/users/${franco.id}`, roberta.token, { name: "Franco R." }, f.updatedAt)).status).toBe(200);

    // Tariffa non ancora fissata: "none". Se un altro la fissa nel frattempo, il secondo viene avvisato.
    expect((await send("PUT", "/fees/2070/1", franco.token, { amountCents: 3000 }, "none")).status).toBe(200);
    expect((await send("PUT", "/fees/2070/1", roberta.token, { amountCents: 3200 }, "none")).status).toBe(409);
    const fees = (await (await api("/fees?year=2070", { token: roberta.token })).json()) as { items: { categoryId: number; updatedAt: string | null }[] };
    const v = fees.items.find((x) => x.categoryId === 1)!.updatedAt!;
    expect((await send("PUT", "/fees/2070/1", roberta.token, { amountCents: 3200 }, v)).status).toBe(200);
  });
});
