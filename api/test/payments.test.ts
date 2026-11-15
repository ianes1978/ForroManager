import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { describeAllocations } from "../src/routes/payments.ts";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Payment { id: number; amountCents: number; method: { code: string }; voided: boolean; voidReason: string | null; allocations: { dueId: number; label: string; amountCents: number }[]; description: string; recordedBy: { name: string }; memberName: string }
interface Due { id: number; kind: string; year: number; month: number | null; amountCents: number; paidCents: number; status: string; adjustmentReason: string | null }

let token: string;
let pkg3: number;
const YEAR = 2050;

async function member(extra: Record<string, unknown> = {}) {
  const res = await api("/members", { token, body: { firstName: "Chiara", lastName: "Lombardi", joinedOn: "2049-01-01", ...extra } });
  const id = ((await res.json()) as { id: number }).id;
  // Quote di base del socio: associativa, gennaio e febbraio (la generazione non crea doppioni).
  await api("/dues/generate", { token, body: { kind: "annuale", year: YEAR } });
  await api("/dues/generate", { token, body: { kind: "mensile", year: YEAR, month: 1 } });
  await api("/dues/generate", { token, body: { kind: "mensile", year: YEAR, month: 2 } });
  return id;
}
async function dues(id: number, year = YEAR): Promise<Due[]> {
  return ((await (await api(`/members/${id}/dues?year=${year}`, { token })).json()) as { items: Due[] }).items;
}
const pay = (body: Record<string, unknown>) => api("/payments", { token, body: { method: "contanti", paidOn: `${YEAR}-03-10`, ...body } });

beforeAll(async () => {
  token = (await loggedInUser()).token;
  await api(`/fees/${YEAR}/1`, { method: "PUT", token, body: { amountCents: 3000 } });
  await api(`/fees/${YEAR}/2`, { method: "PUT", token, body: { amountCents: 1500 } });
  await api(`/fees/${YEAR}/3`, { method: "PUT", token, body: { amountCents: 2500 } });
  pkg3 = ((await (await api("/fee-categories", { token, body: { kind: "pacchetto", name: "3 mesi", months: 3 } })).json()) as { id: number }).id;
  await api(`/fees/${YEAR}/${pkg3}`, { method: "PUT", token, body: { amountCents: 6500 } });
});

describe("registrazione dei pagamenti", () => {
  it("paga una quota esistente e la segna come pagata", async () => {
    const id = await member();
    await api("/dues/generate", { token, body: { kind: "mensile", year: YEAR, month: 3 } });
    const march = (await dues(id)).find((d) => d.month === 3)!;
    const res = await pay({ memberId: id, amountCents: 2500, items: [{ dueId: march.id }], method: "paypal" });
    expect(res.status).toBe(201);
    const p = (await res.json()) as Payment;
    expect(p).toMatchObject({ amountCents: 2500, method: { code: "paypal" }, description: "Mensile marzo 2050", memberName: "Lombardi Chiara" });
    expect((await dues(id)).find((d) => d.month === 3)!.status).toBe("pagata");
  });

  it("copre più mesi insieme, anche futuri non ancora generati e a cavallo d'anno", async () => {
    const id = await member();
    await api(`/fees/${YEAR + 1}/3`, { method: "PUT", token, body: { amountCents: 2600 } });
    const res = await pay({ memberId: id, amountCents: 2500 * 2 + 2600, items: [{ year: YEAR, month: 12 }, { year: YEAR + 1, month: 1 }, { year: YEAR, month: 11 }] });
    expect(res.status).toBe(201);
    const p = (await res.json()) as Payment;
    expect(p.description).toBe("Mensili nov 2050–gen 2051");
    expect(p.allocations.map((a) => a.amountCents)).toEqual([2500, 2500, 2600]);
    expect((await dues(id, YEAR + 1)).find((d) => d.month === 1)!.status).toBe("pagata");
  });

  it("applica il pacchetto ripartendo il prezzo sui mesi", async () => {
    const id = await member();
    const res = await pay({ memberId: id, amountCents: 6500, packageCategoryId: pkg3, items: [{ year: YEAR, month: 4 }, { year: YEAR, month: 5 }, { year: YEAR, month: 6 }] });
    expect(res.status).toBe(201);
    const months = (await dues(id)).filter((d) => d.month !== null && d.month >= 4 && d.month <= 6);
    expect(months.map((d) => d.amountCents)).toEqual([2167, 2167, 2166]);
    expect(months.every((d) => d.status === "pagata" && d.adjustmentReason === "Pacchetto 3 mesi")).toBe(true);
  });

  it("rifiuta il pacchetto con un numero di mesi diverso", async () => {
    const id = await member();
    const res = await pay({ memberId: id, amountCents: 5000, packageCategoryId: pkg3, items: [{ year: YEAR, month: 7 }, { year: YEAR, month: 8 }] });
    expect(await errorCode(res)).toBe("package_not_applicable");
  });

  it("con un importo parziale copre prima le voci più vecchie", async () => {
    const id = await member();
    const list = await dues(id);
    const annual = list.find((d) => d.kind === "annuale")!;
    const jan = list.find((d) => d.month === 1)!;
    const feb = list.find((d) => d.month === 2)!;
    const res = await pay({ memberId: id, amountCents: 4000, items: [{ dueId: feb.id }, { dueId: jan.id }, { dueId: annual.id }] });
    const p = (await res.json()) as Payment;
    expect(p.allocations.map((a) => [a.label, a.amountCents])).toEqual([
      ["Quota associativa 2050", 3000],
      ["Mensile gennaio 2050", 1000],
    ]);
    const after = await dues(id);
    expect(after.find((d) => d.month === 1)!.status).toBe("parziale");
    expect(after.find((d) => d.month === 2)!.paidCents).toBe(0);
  });

  it("rifiuta importi superiori al dovuto, mesi già esistenti, mesi sospesi e quote già pagate", async () => {
    const id = await member();
    const jan = (await dues(id)).find((d) => d.month === 1)!;
    expect(await errorCode(await pay({ memberId: id, amountCents: 9999, items: [{ dueId: jan.id }] }))).toBe("amount_exceeds");
    expect(await errorCode(await pay({ memberId: id, amountCents: 2500, items: [{ year: YEAR, month: 1 }] }))).toBe("due_exists");
    await api(`/members/${id}/suspensions`, { token, body: { from: `${YEAR}-08`, to: `${YEAR}-08` } });
    expect(await errorCode(await pay({ memberId: id, amountCents: 2500, items: [{ year: YEAR, month: 8 }] }))).toBe("suspended_month");
    await pay({ memberId: id, amountCents: 2500, items: [{ dueId: jan.id }] });
    expect(await errorCode(await pay({ memberId: id, amountCents: 100, items: [{ dueId: jan.id }] }))).toBe("due_already_paid");
  });

  it("non permette di pagare quote di un altro socio", async () => {
    const a = await member();
    const b = await member();
    const due = (await dues(b)).find((d) => d.month === 1)!;
    expect((await pay({ memberId: a, amountCents: 100, items: [{ dueId: due.id }] })).status).toBe(404);
  });

  it("valida importo, metodo e voci", async () => {
    const id = await member();
    expect((await pay({ memberId: id, amountCents: 0, items: [{ year: YEAR, month: 9 }] })).status).toBe(422);
    expect((await pay({ memberId: id, amountCents: 12.5, items: [{ year: YEAR, month: 9 }] })).status).toBe(422);
    expect((await pay({ memberId: id, amountCents: 100, items: [] })).status).toBe(422);
    expect((await pay({ memberId: id, amountCents: 100, method: "bitcoin", items: [{ year: YEAR, month: 9 }] })).status).toBe(422);
  });
});

describe("annullamento e consultazione", () => {
  it("annulla un pagamento lasciando traccia e riapre le quote", async () => {
    const id = await member();
    const jan = (await dues(id)).find((d) => d.month === 1)!;
    const p = (await (await pay({ memberId: id, amountCents: 2500, items: [{ dueId: jan.id }] })).json()) as Payment;
    const res = await api(`/payments/${p.id}/void`, { token, body: { reason: "Importo errato" } });
    expect(await res.json()).toMatchObject({ voided: true, voidReason: "Importo errato" });
    expect((await dues(id)).find((d) => d.month === 1)!.paidCents).toBe(0);
    expect(await errorCode(await api(`/payments/${p.id}/void`, { token, body: { reason: "di nuovo" } }))).toBe("already_voided");
    const still = await env.DB.prepare("SELECT COUNT(*) AS n FROM payments WHERE id = ?1").bind(p.id).first<{ n: number }>();
    expect(still!.n).toBe(1);
    const audit = await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE entity = 'payment' AND entity_id = ?1").bind(p.id).first<{ n: number }>();
    expect(audit!.n).toBe(2);
  });

  it("elenca i pagamenti filtrando per socio, metodo e periodo", async () => {
    const id = await member();
    await pay({ memberId: id, amountCents: 2500, method: "bonifico", paidOn: `${YEAR}-05-02`, items: [{ year: YEAR, month: 10 }] });
    await pay({ memberId: id, amountCents: 2500, method: "contanti", paidOn: `${YEAR}-06-02`, items: [{ year: YEAR, month: 9 }] });
    const byMember = (await (await api(`/payments?memberId=${id}`, { token })).json()) as { items: Payment[] };
    expect(byMember.items).toHaveLength(2);
    expect(byMember.items[0]!.description).toBe("Mensile settembre 2050");
    const byMethod = (await (await api(`/payments?memberId=${id}&method=bonifico`, { token })).json()) as { items: Payment[] };
    expect(byMethod.items).toHaveLength(1);
    const byPeriod = (await (await api(`/payments?memberId=${id}&from=${YEAR}-06-01&to=${YEAR}-06-30`, { token })).json()) as { items: Payment[] };
    expect(byPeriod.items.map((p) => p.description)).toEqual(["Mensile settembre 2050"]);
  });
});

describe("metodi di pagamento", () => {
  it("aggiunge, rinomina e disattiva un metodo", async () => {
    const created = await api("/payment-methods", { token, body: { label: "Satispay" } });
    expect(await created.json()).toEqual({ code: "satispay", label: "Satispay", active: true });
    expect((await api("/payment-methods", { token, body: { label: "satispay" } })).status).toBe(409);
    const off = await api("/payment-methods/satispay", { method: "PATCH", token, body: { active: false } });
    expect(await off.json()).toMatchObject({ active: false });
    const id = await member();
    expect((await pay({ memberId: id, amountCents: 100, method: "satispay", items: [{ year: YEAR, month: 9 }] })).status).toBe(422);
  });
});

describe("descrizione dei pagamenti", () => {
  it("riassume voci miste", () => {
    expect(
      describeAllocations([
        { kind: "annuale", year: 2026, month: null, product_name: null },
        { kind: "mensile", year: 2026, month: 1, product_name: null },
        { kind: "prodotto", year: 2026, month: null, product_name: "Maglietta" },
      ]),
    ).toBe("Quota associativa 2026 + Mensile gennaio 2026 + Maglietta");
  });
});
