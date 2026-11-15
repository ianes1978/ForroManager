import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Due { id: number; kind: string; year: number; month: number | null; label: string; amountCents: number; baseAmountCents: number; adjustmentReason: string | null; status: string; remainingCents: number }
interface DuesResponse { year: number; items: Due[]; summary: { arrearsCents: number; inRegola: boolean; openChargesCents: number } }

// Ogni file di test ha un database proprio: anni "lontani" evitano interferenze tra i test.
let token: string;

async function member(extra: Record<string, unknown> = {}): Promise<number> {
  const res = await api("/members", { token, body: { firstName: "Socio", lastName: "Prova", joinedOn: "2020-01-01", ...extra } });
  return ((await res.json()) as { id: number }).id;
}
const setRate = (year: number, categoryId: number, amountCents: number) => api(`/fees/${year}/${categoryId}`, { method: "PUT", token, body: { amountCents } });
const generate = (body: Record<string, unknown>) => api("/dues/generate", { token, body });
async function dues(memberId: number, year: number): Promise<DuesResponse> {
  return (await (await api(`/members/${memberId}/dues?year=${year}`, { token })).json()) as DuesResponse;
}

beforeAll(async () => {
  token = (await loggedInUser()).token;
});

describe("generazione delle quote", () => {
  it("chiede di fissare prima gli importi mancanti", async () => {
    await member();
    const res = await generate({ kind: "annuale", year: 2040 });
    expect(res.status).toBe(422);
    expect(((await res.json()) as { error: { message: string } }).error.message).toContain("annuale ordinaria");
  });

  it("crea l'associativa con la tariffa del socio ed è idempotente", async () => {
    const ordinary = await member();
    const reduced = await member({ annualCategoryId: 2 });
    await setRate(2041, 1, 3000);
    await setRate(2041, 2, 1500);
    const first = (await (await generate({ kind: "annuale", year: 2041 })).json()) as { created: number; alreadyPresent: number };
    expect(first.created).toBeGreaterThanOrEqual(2);
    const second = (await (await generate({ kind: "annuale", year: 2041 })).json()) as { created: number; alreadyPresent: number };
    expect(second.created).toBe(0);
    expect(second.alreadyPresent).toBe(first.created + first.alreadyPresent);
    expect((await dues(ordinary, 2041)).items.find((d) => d.kind === "annuale")!.amountCents).toBe(3000);
    expect((await dues(reduced, 2041)).items.find((d) => d.kind === "annuale")!.amountCents).toBe(1500);
  });

  it("esclude i sospesi, i cessati e chi si iscrive dopo il mese", async () => {
    await setRate(2042, 3, 2500);
    const active = await member();
    const suspended = await member();
    const ceased = await member();
    const later = await member({ joinedOn: "2042-04-02" });
    await api(`/members/${suspended}/suspensions`, { token, body: { from: "2042-02", to: "2042-04" } });
    await api(`/members/${ceased}/cease`, { token, body: { ceasedOn: "2041-12-31" } });

    const res = (await (await generate({ kind: "mensile", year: 2042, month: 3 })).json()) as { suspended: number };
    expect(res.suspended).toBeGreaterThanOrEqual(1);
    const has = async (id: number) => (await dues(id, 2042)).items.some((d) => d.kind === "mensile" && d.month === 3);
    expect(await has(active)).toBe(true);
    expect(await has(suspended)).toBe(false);
    expect(await has(ceased)).toBe(false);
    expect(await has(later)).toBe(false);
    await generate({ kind: "mensile", year: 2042, month: 4 });
    expect((await dues(later, 2042)).items.some((d) => d.month === 4)).toBe(true);
  });

  it("valida il mese solo per le mensili", async () => {
    expect((await generate({ kind: "mensile", year: 2042 })).status).toBe(422);
    expect((await generate({ kind: "annuale", year: 2042, month: 1 })).status).toBe(422);
  });
});

describe("scheda quote del socio", () => {
  it("mostra stato, arretrati e la regolarità, con le voci aperte degli anni precedenti", async () => {
    await setRate(2020, 3, 2500);
    const id = await member();
    await generate({ kind: "mensile", year: 2020, month: 12 });
    const res = await dues(id, 2021);
    expect(res.items.map((d) => d.label)).toContain("Mensile dicembre 2020");
    expect(res.summary).toMatchObject({ arrearsCents: 2500, inRegola: false });
  });
});

describe("modifica e annullamento di una quota", () => {
  async function oneDue(): Promise<{ member: number; due: Due }> {
    await setRate(2043, 3, 2500);
    const id = await member();
    await generate({ kind: "mensile", year: 2043, month: 6 });
    const due = (await dues(id, 2043)).items.find((d) => d.month === 6)!;
    return { member: id, due };
  }

  it("riduce l'importo con un motivo e lo ripristina senza", async () => {
    const { due } = await oneDue();
    expect((await api(`/dues/${due.id}/adjust`, { token, body: { amountCents: 1250 } })).status).toBe(422);
    const reduced = (await (await api(`/dues/${due.id}/adjust`, { token, body: { amountCents: 1250, reason: "Iscrizione a metà mese" } })).json()) as Due;
    expect(reduced).toMatchObject({ amountCents: 1250, baseAmountCents: 2500, adjustmentReason: "Iscrizione a metà mese" });
    const restored = (await (await api(`/dues/${due.id}/adjust`, { token, body: { amountCents: 2500 } })).json()) as Due;
    expect(restored).toMatchObject({ amountCents: 2500, adjustmentReason: null });
  });

  it("non scende sotto il già pagato e non annulla quote con pagamenti", async () => {
    const { member: id, due } = await oneDue();
    const me = await env.DB.prepare("SELECT id FROM users LIMIT 1").first<{ id: number }>();
    const p = await env.DB.prepare(
      `INSERT INTO payments (member_id, paid_on, amount_cents, method_id, recorded_by, created_at) VALUES (?1, '2043-06-01', 2000, 1, ?2, '2043-06-01T00:00:00Z') RETURNING id`,
    )
      .bind(id, me!.id)
      .first<{ id: number }>();
    await env.DB.prepare("INSERT INTO payment_allocations (payment_id, due_id, amount_cents) VALUES (?1, ?2, 2000)").bind(p!.id, due.id).run();
    const low = await api(`/dues/${due.id}/adjust`, { token, body: { amountCents: 1000, reason: "x" } });
    expect(await errorCode(low)).toBe("below_paid");
    const cancel = await api(`/dues/${due.id}/cancel`, { token, body: { reason: "errore" } });
    expect(await errorCode(cancel)).toBe("has_payments");
  });

  it("elimina una quota mai pagata; con pagamenti, anche annullati, la rifiuta", async () => {
    const { member: id, due } = await oneDue();
    expect((await api(`/dues/${due.id}`, { token, method: "DELETE" })).status).toBe(204);
    expect((await dues(id, 2043)).items.some((d) => d.id === due.id)).toBe(false);
    expect((await api(`/dues/${due.id}`, { token, method: "DELETE" })).status).toBe(404);

    const other = await oneDue();
    const me = await env.DB.prepare("SELECT id FROM users LIMIT 1").first<{ id: number }>();
    const p = await env.DB.prepare(
      `INSERT INTO payments (member_id, paid_on, amount_cents, method_id, recorded_by, created_at, voided_at, voided_by, void_reason)
       VALUES (?1, '2043-06-01', 2000, 1, ?2, '2043-06-01T00:00:00Z', '2043-06-02T00:00:00Z', ?2, 'Doppio') RETURNING id`,
    )
      .bind(other.member, me!.id)
      .first<{ id: number }>();
    await env.DB.prepare("INSERT INTO payment_allocations (payment_id, due_id, amount_cents) VALUES (?1, ?2, 2000)").bind(p!.id, other.due.id).run();
    expect(await errorCode(await api(`/dues/${other.due.id}`, { token, method: "DELETE" }))).toBe("has_payments");
    expect((await api(`/dues/${other.due.id}/cancel`, { token, body: { reason: "Esonerato" } })).status).toBe(204);
  });

  it("annulla una quota senza pagamenti, che non compare più e si può rigenerare", async () => {
    const { member: id, due } = await oneDue();
    expect((await api(`/dues/${due.id}/cancel`, { token, body: { reason: "Generata per errore" } })).status).toBe(204);
    expect((await dues(id, 2043)).items.some((d) => d.month === 6)).toBe(false);
    await generate({ kind: "mensile", year: 2043, month: 6 });
    expect((await dues(id, 2043)).items.some((d) => d.month === 6)).toBe(true);
  });
});

describe("prodotti e addebiti", () => {
  it("addebita un prodotto da saldare senza togliere la regolarità", async () => {
    const product = (await (await api("/products", { token, body: { name: "Maglietta", type: "merchandising", priceCents: 1500 } })).json()) as { id: number };
    const id = await member({ joinedOn: "2026-11-01" });
    const res = await api(`/members/${id}/charges`, { token, body: { productId: product.id, chargedOn: "2026-11-15" } });
    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ label: "Maglietta", amountCents: 1500, status: "da_pagare" });
    const s = (await dues(id, 2026)).summary;
    expect(s).toMatchObject({ inRegola: true, openChargesCents: 1500 });
  });

  it("chiede il motivo se il prezzo è diverso e rifiuta prodotti disattivati", async () => {
    const product = (await (await api("/products", { token, body: { name: "Stage", type: "stage", priceCents: 4000 } })).json()) as { id: number };
    const id = await member();
    expect((await api(`/members/${id}/charges`, { token, body: { productId: product.id, amountCents: 3000 } })).status).toBe(422);
    expect((await api(`/members/${id}/charges`, { token, body: { productId: product.id, amountCents: 3000, reason: "Sconto" } })).status).toBe(201);
    await api(`/products/${product.id}`, { method: "PATCH", token, body: { active: false } });
    const res = await api(`/members/${id}/charges`, { token, body: { productId: product.id } });
    expect(await errorCode(res)).toBe("product_inactive");
    const list = (await (await api("/products", { token })).json()) as { items: { id: number }[] };
    expect(list.items.some((p) => p.id === product.id)).toBe(false);
  });
});
