import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Member {
  id: number;
  firstName: string;
  lastName: string;
  email: string | null;
  status: string;
  ceasedOn: string | null;
  annualCategory: { id: number; name: string };
  suspensions: { id: number; from: string; to: string }[];
}

const base = { firstName: "Giulia", lastName: "Ferri", joinedOn: "2026-09-12" };

async function newMember(token: string, extra: Record<string, unknown> = {}): Promise<Member> {
  const res = await api("/members", { token, body: { ...base, ...extra } });
  if (res.status !== 201) throw new Error(`${res.status} ${await res.text()}`);
  return (await res.json()) as Member;
}

describe("soci", () => {
  it("crea un socio con le tariffe predefinite e lo registra nel registro", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token, { email: "", phone: "333 1234567", notes: "Preferisce bonifico" });
    expect(m).toMatchObject({ status: "attivo", email: null, annualCategory: { name: "Ordinaria" }, suspensions: [] });
    const audit = await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE entity = 'member' AND entity_id = ?1").bind(m.id).first<{ n: number }>();
    expect(audit!.n).toBe(1);
  });

  it("assegna la tariffa associativa ridotta e rifiuta tariffe del tipo sbagliato", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token, { annualCategoryId: 2 });
    expect(m.annualCategory.name).toBe("Ridotta");
    const wrong = await api("/members", { token: me.token, body: { ...base, annualCategoryId: 3 } });
    expect(wrong.status).toBe(422);
  });

  it("valida i dati obbligatori, la data e i contatti", async () => {
    const me = await loggedInUser();
    const res = await api("/members", {
      token: me.token,
      body: { firstName: "", lastName: "X", joinedOn: "2026-13-40", email: "non-email", phone: "abc" },
    });
    expect(res.status).toBe(422);
    const fields = ((await res.json()) as { error: { details: { field: string }[] } }).error.details.map((d) => d.field);
    expect(fields).toEqual(expect.arrayContaining(["firstName", "joinedOn", "email", "phone"]));
  });

  it("cerca per nome o cognome, anche con più parole, e filtra per stato", async () => {
    const me = await loggedInUser();
    const a = await newMember(me.token, { firstName: "Zeno", lastName: "Cercabile" });
    await newMember(me.token, { firstName: "Zeno", lastName: "Altro" });
    const ceased = await newMember(me.token, { firstName: "Zeno", lastName: "Cessato" });
    await api(`/members/${ceased.id}/cease`, { token: me.token, body: {} });

    const byWords = (await (await api("/members?q=zeno%20cerca", { token: me.token })).json()) as { items: Member[] };
    expect(byWords.items.map((m) => m.id)).toEqual([a.id]);
    const active = (await (await api("/members?q=zeno", { token: me.token })).json()) as { items: Member[] };
    expect(active.items).toHaveLength(2);
    const all = (await (await api("/members?q=zeno&status=tutti", { token: me.token })).json()) as { items: Member[] };
    expect(all.items).toHaveLength(3);
    const wildcard = (await (await api("/members?q=%25", { token: me.token })).json()) as { items: Member[] };
    expect(wildcard.items).toHaveLength(0);
  });

  it("modifica solo i campi indicati e registra prima e dopo", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    const res = await api(`/members/${m.id}`, { method: "PATCH", token: me.token, body: { lastName: "Ferri-Bianchi", email: "g@esempio.it" } });
    expect(await res.json()).toMatchObject({ firstName: "Giulia", lastName: "Ferri-Bianchi", email: "g@esempio.it" });
    const audit = await env.DB.prepare("SELECT details FROM audit_log WHERE entity = 'member' AND entity_id = ?1 AND action = 'update'").bind(m.id).first<{ details: string }>();
    expect(JSON.parse(audit!.details)).toEqual({
      lastName: { before: "Ferri", after: "Ferri-Bianchi" },
      email: { before: null, after: "g@esempio.it" },
    });
  });

  it("cessa e riattiva un socio", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    const ceased = await api(`/members/${m.id}/cease`, { token: me.token, body: { ceasedOn: "2026-10-31" } });
    expect(await ceased.json()).toMatchObject({ status: "cessato", ceasedOn: "2026-10-31" });
    const again = await api(`/members/${m.id}/cease`, { token: me.token, body: {} });
    expect(again.status).toBe(409);
    const back = await api(`/members/${m.id}/reactivate`, { method: "POST", token: me.token });
    expect(await back.json()).toMatchObject({ status: "attivo", ceasedOn: null });
  });

  it("non accetta una cessazione precedente all'iscrizione", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    expect((await api(`/members/${m.id}/cease`, { token: me.token, body: { ceasedOn: "2025-01-01" } })).status).toBe(422);
  });

  it("risponde 404 per soci inesistenti", async () => {
    const me = await loggedInUser();
    expect((await api("/members/99999", { token: me.token })).status).toBe(404);
  });
});

describe("sospensioni", () => {
  it("registra una sospensione e la mostra nella scheda", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    const res = await api(`/members/${m.id}/suspensions`, { token: me.token, body: { from: "2026-07", to: "2026-08", reason: "Pausa estiva" } });
    expect(res.status).toBe(201);
    const detail = (await (await api(`/members/${m.id}`, { token: me.token })).json()) as Member;
    expect(detail.suspensions).toEqual([expect.objectContaining({ from: "2026-07", to: "2026-08", reason: "Pausa estiva" })]);
  });

  it("rifiuta periodi invertiti o sovrapposti, anche a cavallo d'anno", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    expect((await api(`/members/${m.id}/suspensions`, { token: me.token, body: { from: "2026-09", to: "2026-07" } })).status).toBe(422);
    await api(`/members/${m.id}/suspensions`, { token: me.token, body: { from: "2026-12", to: "2027-02" } });
    const overlap = await api(`/members/${m.id}/suspensions`, { token: me.token, body: { from: "2027-01", to: "2027-03" } });
    expect(overlap.status).toBe(409);
    expect(await errorCode(overlap)).toBe("suspension_overlap");
  });

  it("annulla una sospensione, che non compare più", async () => {
    const me = await loggedInUser();
    const m = await newMember(me.token);
    const s = (await (await api(`/members/${m.id}/suspensions`, { token: me.token, body: { from: "2026-07", to: "2026-07" } })).json()) as { id: number };
    expect((await api(`/members/${m.id}/suspensions/${s.id}/cancel`, { method: "POST", token: me.token })).status).toBe(204);
    expect((await api(`/members/${m.id}/suspensions/${s.id}/cancel`, { method: "POST", token: me.token })).status).toBe(404);
    const detail = (await (await api(`/members/${m.id}`, { token: me.token })).json()) as Member;
    expect(detail.suspensions).toEqual([]);
  });
});
