import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Fee { categoryId: number; kind: string; name: string; amountCents: number | null }

describe("tariffe", () => {
  it("elenca le categorie dell'anno con importo non ancora fissato", async () => {
    const me = await loggedInUser();
    const res = await api("/fees?year=2031", { token: me.token });
    expect(res.status).toBe(200);
    const { items } = (await res.json()) as { items: Fee[] };
    expect(items.map((f) => `${f.kind}:${f.name}`)).toEqual(
      expect.arrayContaining(["annuale:Ordinaria", "annuale:Ridotta", "mensile:Ordinaria"]),
    );
    expect(items.every((f) => f.amountCents === null)).toBe(true);
  });

  it("fissa e modifica l'importo di un anno, lasciando traccia nel registro", async () => {
    const me = await loggedInUser();
    expect((await api("/fees/2030/1", { method: "PUT", token: me.token, body: { amountCents: 3000 } })).status).toBe(200);
    const res = await api("/fees/2030/1", { method: "PUT", token: me.token, body: { amountCents: 3500 } });
    expect(((await res.json()) as { fee: Fee }).fee.amountCents).toBe(3500);
    const other = (await (await api("/fees?year=2029", { token: me.token })).json()) as { items: Fee[] };
    expect(other.items.find((f) => f.categoryId === 1)!.amountCents).toBeNull();
    const audit = await env.DB.prepare("SELECT details FROM audit_log WHERE entity = 'fee_rate' ORDER BY id DESC LIMIT 1").first<{ details: string }>();
    expect(JSON.parse(audit!.details)).toMatchObject({ year: 2030, before: 3000, after: 3500 });
  });

  it("rifiuta importi non interi o negativi", async () => {
    const me = await loggedInUser();
    expect((await api("/fees/2030/1", { method: "PUT", token: me.token, body: { amountCents: 25.5 } })).status).toBe(422);
    expect((await api("/fees/2030/1", { method: "PUT", token: me.token, body: { amountCents: -1 } })).status).toBe(422);
  });

  it("crea pacchetti con il numero di mesi e rifiuta i duplicati", async () => {
    const me = await loggedInUser();
    const res = await api("/fee-categories", { token: me.token, body: { kind: "pacchetto", name: "3 mesi", months: 3 } });
    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ kind: "pacchetto", months: 3, active: true });
    const dup = await api("/fee-categories", { token: me.token, body: { kind: "pacchetto", name: "3 MESI", months: 3 } });
    expect(dup.status).toBe(409);
    expect(await errorCode(dup)).toBe("category_exists");
    const noMonths = await api("/fee-categories", { token: me.token, body: { kind: "pacchetto", name: "Senza mesi" } });
    expect(noMonths.status).toBe(422);
    const monthsOnAnnual = await api("/fee-categories", { token: me.token, body: { kind: "annuale", name: "Strana", months: 3 } });
    expect(monthsOnAnnual.status).toBe(422);
  });

  it("rinomina e disattiva una categoria", async () => {
    const me = await loggedInUser();
    const created = (await (await api("/fee-categories", { token: me.token, body: { kind: "annuale", name: "Studenti" } })).json()) as { id: number };
    const res = await api(`/fee-categories/${created.id}`, { method: "PATCH", token: me.token, body: { name: "Studenti under 25", active: false } });
    expect(await res.json()).toMatchObject({ name: "Studenti under 25", active: false });
  });

  it("con applyToUnpaid aggiorna solo le quote senza pagamenti né riduzioni", async () => {
    const me = await loggedInUser();
    const T = "2026-01-01T00:00:00Z";
    const member = await env.DB.prepare(
      `INSERT INTO members (first_name, last_name, joined_on, annual_category_id, monthly_category_id, created_at, created_by, updated_at, updated_by)
       VALUES ('A', 'B', '2026-01-01', 1, 3, ?1, ?2, ?1, ?2) RETURNING id`,
    )
      .bind(T, me.id)
      .first<{ id: number }>();
    const insertDue = (month: number, amount: number, reason: string | null) =>
      env.DB.prepare(
        `INSERT INTO dues (member_id, kind, year, month, category_id, base_amount_cents, amount_cents, adjustment_reason, charged_on, created_at, created_by)
         VALUES (?1, 'mensile', 2032, ?2, 3, 2500, ?3, ?4, '2032-01-01', ?5, ?6) RETURNING id`,
      )
        .bind(member!.id, month, amount, reason, T, me.id)
        .first<{ id: number }>();
    const free = await insertDue(1, 2500, null);
    const reduced = await insertDue(2, 1500, "Agevolazione");
    const paid = await insertDue(3, 2500, null);
    const pay = await env.DB.prepare(
      `INSERT INTO payments (member_id, paid_on, amount_cents, method_id, recorded_by, created_at)
       VALUES (?1, '2032-03-01', 100, 1, ?2, ?3) RETURNING id`,
    )
      .bind(member!.id, me.id, T)
      .first<{ id: number }>();
    await env.DB.prepare("INSERT INTO payment_allocations (payment_id, due_id, amount_cents) VALUES (?1, ?2, 100)").bind(pay!.id, paid!.id).run();

    const res = await api("/fees/2032/3", { method: "PUT", token: me.token, body: { amountCents: 2800, applyToUnpaid: true } });
    expect(((await res.json()) as { updatedDues: number }).updatedDues).toBe(1);
    const amounts = await env.DB.prepare("SELECT id, amount_cents FROM dues WHERE member_id = ?1 ORDER BY month").bind(member!.id).all<{ id: number; amount_cents: number }>();
    expect(amounts.results.map((r) => r.amount_cents)).toEqual([2800, 1500, 2500]);
    expect([free!.id, reduced!.id, paid!.id]).toEqual(amounts.results.map((r) => r.id));
  });
});
