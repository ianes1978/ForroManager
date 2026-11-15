import { beforeAll, describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Expense { id: number; spentOn: string; description: string; amountCents: number; category: { id: number; name: string }; method: { code: string } | null; advancedBy: string | null; reimbursedOn: string | null; toReimburse: boolean; hasReceipt: boolean; updatedAt: string }
interface List { items: Expense[]; totalCents: number; toReimburseCents: number; toReimburseCount: number }

let token: string;
let affitto: number;
const Y = 2061;
const create = (body: Record<string, unknown>) => api("/expenses", { token, body: { spentOn: `${Y}-03-05`, categoryId: affitto, ...body } });
const list = async (q = "") => (await (await api(`/expenses?from=${Y}-01-01&to=${Y}-12-31${q}`, { token })).json()) as List;

beforeAll(async () => {
  token = (await loggedInUser()).token;
  const cats = (await (await api("/expense-categories", { token })).json()) as { items: { id: number; name: string }[] };
  affitto = cats.items.find((c) => c.name === "Affitto sala")!.id;
});

describe("spese", () => {
  it("registra spese pagate dalla cassa o anticipate, e le filtra", async () => {
    const sala = (await (await create({ description: "Sala marzo", amountCents: 20000, method: "bonifico", hasReceipt: true })).json()) as Expense;
    expect(sala).toMatchObject({ description: "Sala marzo", method: { code: "bonifico" }, advancedBy: null, toReimburse: false, hasReceipt: true, category: { name: "Affitto sala" } });
    const casse = (await (await create({ description: "Cassa bluetooth", amountCents: 4500, advancedBy: "Stefano" })).json()) as Expense;
    expect(casse).toMatchObject({ advancedBy: "Stefano", toReimburse: true, hasReceipt: false });

    const all = await list();
    expect(all.totalCents).toBe(24500);
    expect(all.toReimburseCents).toBeGreaterThanOrEqual(4500);
    expect((await list("&toReimburse=true")).items.map((e) => e.description)).toContain("Cassa bluetooth");
    expect((await list("&noReceipt=true")).items.map((e) => e.description)).toEqual(["Cassa bluetooth"]);
  });

  it("segna rimborso e ricevuta, con controllo delle modifiche in contemporanea", async () => {
    const e = (await (await create({ description: "Corde", amountCents: 1200, advancedBy: "Giulia" })).json()) as Expense;
    const ok = await api(`/expenses/${e.id}`, { token, method: "PATCH", body: { reimbursedOn: `${Y}-03-20`, method: "contanti", hasReceipt: true }, headers: { "If-Match": e.updatedAt } });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ reimbursedOn: `${Y}-03-20`, toReimburse: false, hasReceipt: true, method: { code: "contanti" } });
    expect(await errorCode(await api(`/expenses/${e.id}`, { token, method: "PATCH", body: { amountCents: 1300 }, headers: { "If-Match": e.updatedAt } }))).toBe("stale");
    // Senza chi l'ha anticipata il rimborso non ha senso e sparisce.
    const cassa = (await (await api(`/expenses/${e.id}`, { token, method: "PATCH", body: { advancedBy: null } })).json()) as Expense;
    expect(cassa).toMatchObject({ advancedBy: null, reimbursedOn: null, toReimburse: false });
    expect((await create({ description: "x", amountCents: 100, reimbursedOn: `${Y}-03-01` })).status).toBe(422);
  });

  it("elimina una spesa; le categorie usate non si eliminano", async () => {
    const e = (await (await create({ description: "Doppione", amountCents: 999 })).json()) as Expense;
    expect((await api(`/expenses/${e.id}`, { token, method: "DELETE" })).status).toBe(204);
    expect((await api(`/expenses/${e.id}`, { token, method: "DELETE" })).status).toBe(404);
    expect(await errorCode(await api(`/expense-categories/${affitto}`, { token, method: "DELETE" }))).toBe("category_in_use");
    const nuova = (await (await api("/expense-categories", { token, body: { name: "Pulizie" } })).json()) as { id: number };
    expect((await api(`/expense-categories/${nuova.id}`, { token, method: "DELETE" })).status).toBe(204);
  });

  it("entra nel riepilogo con saldo e nel report completo", async () => {
    const income = (await (await api(`/reports/income?year=${Y}`, { token })).json()) as {
      totalCents: number; balanceCents: number; expenses: { totalCents: number; byMonth: number[]; byCategory: { name: string; cents: number }[]; noReceiptCount: number };
    };
    expect(income.expenses.byMonth[2]).toBe(income.expenses.totalCents);
    expect(income.balanceCents).toBe(income.totalCents - income.expenses.totalCents);
    expect(income.expenses.byCategory[0]).toMatchObject({ name: "Affitto sala" });
    const full = (await (await api(`/reports/full?year=${Y}`, { token })).json()) as { expenses: Record<string, unknown>[] };
    expect(full.expenses.find((e) => e.descrizione === "Cassa bluetooth")).toMatchObject({ anticipataDa: "Stefano", daRimborsare: true, ricevuta: false });
  });
});
