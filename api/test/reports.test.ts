import { beforeAll, describe, expect, it } from "vitest";
import { csvCell, euro, toCsv } from "../src/lib/csv.ts";
import { todayIso } from "../src/lib/time.ts";
import { api, loggedInUser } from "./helpers.ts";

let token: string;
const today = todayIso();
const YEAR = Number(today.slice(0, 4));
const MONTH = Number(today.slice(5, 7));

async function member(lastName: string) {
  const res = await api("/members", { token, body: { firstName: "Test", lastName, joinedOn: `${YEAR}-01-01`, notes: "=HYPERLINK(\"x\")" } });
  return ((await res.json()) as { id: number }).id;
}

let inRegola: number, inArrears: number;

beforeAll(async () => {
  token = (await loggedInUser()).token;
  await api(`/fees/${YEAR}/1`, { method: "PUT", token, body: { amountCents: 3000 } });
  await api(`/fees/${YEAR}/3`, { method: "PUT", token, body: { amountCents: 2500 } });
  inRegola = await member("Puntuale");
  inArrears = await member("Ritardatario");
  await api("/dues/generate", { token, body: { kind: "annuale", year: YEAR } });
  await api("/dues/generate", { token, body: { kind: "mensile", year: YEAR, month: MONTH } });
  const dues = (await (await api(`/members/${inRegola}/dues`, { token })).json()) as { items: { id: number }[] };
  await api("/payments", { token, body: { memberId: inRegola, amountCents: 5500, method: "bonifico", paidOn: today, items: dues.items.map((d) => ({ dueId: d.id })) } });
  const product = (await (await api("/products", { token, body: { name: "Maglietta", type: "merchandising", priceCents: 1500 } })).json()) as { id: number };
  await api(`/members/${inRegola}/charges`, { token, body: { productId: product.id } });
});

describe("riepilogo", () => {
  it("indica chi è in regola e chi no, con i totali", async () => {
    const r = (await (await api("/reports/status", { token })).json()) as {
      activeMembers: number; inRegola: number; notInRegola: number; arrearsTotalCents: number; openChargesTotalCents: number; members: { id: number; arrearsCents: number; openChargesCents: number }[];
    };
    expect(r).toMatchObject({ activeMembers: 2, inRegola: 1, notInRegola: 1, arrearsTotalCents: 5500, openChargesTotalCents: 1500 });
    expect(r.members.find((m) => m.id === inArrears)!.arrearsCents).toBe(5500);
    expect(r.members.find((m) => m.id === inRegola)!).toMatchObject({ arrearsCents: 0, openChargesCents: 1500 });
  });

  it("calcola gli incassi per mese, metodo e voce", async () => {
    const r = (await (await api(`/reports/income?year=${YEAR}`, { token })).json()) as {
      totalCents: number; byMonth: number[]; byMethod: { code: string; cents: number }[]; byKind: Record<string, number>;
    };
    expect(r.totalCents).toBe(5500);
    expect(r.byMonth[MONTH - 1]).toBe(5500);
    expect(r.byMethod.find((m) => m.code === "bonifico")!.cents).toBe(5500);
    expect(r.byMethod.find((m) => m.code === "paypal")!.cents).toBe(0);
    expect(r.byKind).toEqual({ annuale: 3000, mensile: 2500, prodotto: 0 });
  });

  it("mostra nell'elenco soci il riepilogo e filtra chi ha arretrati", async () => {
    const all = (await (await api("/members", { token })).json()) as { items: { id: number; summary: { inRegola: boolean; openChargesCents: number } }[] };
    expect(all.items.find((m) => m.id === inRegola)!.summary).toMatchObject({ inRegola: true, openChargesCents: 1500 });
    const late = (await (await api("/members?filter=arretrati", { token })).json()) as { items: { id: number }[] };
    expect(late.items.map((m) => m.id)).toEqual([inArrears]);
  });
});

describe("moduli", () => {
  it("consegna a tutti, registra la restituzione e conta i mancanti", async () => {
    const form = (await (await api("/forms", { token, body: { name: "Consenso privacy", required: true } })).json()) as { id: number };
    const res = (await (await api(`/forms/${form.id}/deliver-all`, { token, body: { deliveredOn: "2026-09-10" } })).json()) as { delivered: number };
    expect(res.delivered).toBe(2);
    expect(((await (await api(`/forms/${form.id}/deliver-all`, { token, body: {} })).json()) as { delivered: number }).delivered).toBe(0);

    const ret = await api(`/members/${inRegola}/forms/${form.id}`, { method: "PUT", token, body: { returnedOn: "2026-09-20" } });
    expect(await ret.json()).toMatchObject({ deliveredOn: "2026-09-10", returnedOn: "2026-09-20" });
    const bad = await api(`/members/${inRegola}/forms/${form.id}`, { method: "PUT", token, body: { returnedOn: "2026-09-01" } });
    expect(bad.status).toBe(422);

    const list = (await (await api("/forms", { token })).json()) as { items: { id: number; delivered: number; returned: number }[] };
    expect(list.items.find((f) => f.id === form.id)).toMatchObject({ delivered: 2, returned: 1 });
    const missing = (await (await api(`/forms/${form.id}/members?missing=true`, { token })).json()) as { items: { memberId: number }[] };
    expect(missing.items.map((m) => m.memberId)).toEqual([inArrears]);
    const filtered = (await (await api("/members?filter=moduli", { token })).json()) as { items: { id: number; summary: { missingForms: number } }[] };
    expect(filtered.items.map((m) => m.id)).toEqual([inArrears]);

    const mine = (await (await api(`/members/${inRegola}/forms`, { token })).json()) as { items: { formName: string }[] };
    expect(mine.items.map((f) => f.formName)).toEqual(["Consenso privacy"]);
    const undo = await api(`/members/${inRegola}/forms/${form.id}`, { method: "PUT", token, body: { delivered: false } });
    expect(await undo.json()).toMatchObject({ deliveredOn: null });
  });
});

describe("esportazione CSV", () => {
  it("esporta i soci con separatore punto e virgola e neutralizza le formule", async () => {
    const res = await api("/export/members.csv", { token });
    expect(res.headers.get("content-type")).toContain("text/csv");
    expect(res.headers.get("cache-control")).toBe("no-store");
    const bytes = new Uint8Array(await res.arrayBuffer());
    expect([...bytes.slice(0, 3)]).toEqual([0xef, 0xbb, 0xbf]); // BOM UTF-8, per Excel
    const text = new TextDecoder().decode(bytes);
    const lines = text.trim().split("\r\n");
    expect(lines[0]).toContain("Cognome;Nome;Email");
    const late = lines.find((l) => l.includes("Ritardatario"))!;
    expect(late).toContain(";no;55,00;");
    expect(late).toContain(`"'=HYPERLINK(""x"")"`);
  });

  it("esporta i pagamenti con le voci pagate", async () => {
    const text = await (await api(`/export/payments.csv?from=${YEAR}-01-01&to=${YEAR}-12-31`, { token })).text();
    const lines = text.trim().split("\r\n");
    expect(lines).toHaveLength(2);
    expect(lines[1]).toContain(";55,00;Bonifico;");
    expect(lines[1]).toContain(`Quota associativa ${YEAR} + Mensile`);
  });

  it("formatta celle e importi", () => {
    expect(euro(2500)).toBe("25,00");
    expect(euro(5)).toBe("0,05");
    expect(csvCell('a;b"c')).toBe('"a;b""c"');
    expect(csvCell("-1")).toBe("'-1");
    expect(toCsv(["a"], [[null]])).toBe("﻿a\r\n\r\n");
  });
});

describe("registro modifiche", () => {
  it("elenca le modifiche con autore e descrizione, dalla più recente", async () => {
    const res = (await (await api("/audit?limit=5", { token })).json()) as { items: { id: number; user: { name: string } | null; description: string }[] };
    expect(res.items.length).toBe(5);
    expect(res.items[0]!.id).toBeGreaterThan(res.items[1]!.id);
    expect(res.items.every((i) => i.user?.name)).toBe(true);
    const payments = (await (await api("/audit?entity=payment", { token })).json()) as { items: { description: string }[] };
    expect(payments.items[0]!.description).toBe("ha registrato un pagamento");
    const older = (await (await api(`/audit?beforeId=${res.items[4]!.id}&limit=1`, { token })).json()) as { items: { id: number }[] };
    expect(older.items[0]!.id).toBeLessThan(res.items[4]!.id);
  });
});
