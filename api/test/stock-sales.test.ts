import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Variant { id: number; size: string; color: string; label: string; stock: number; low: boolean; active: boolean }
interface Product { id: number; tracksStock: boolean; variants: Variant[] }
interface Sale { id: number; label: string; quantity: number; amountCents: number; remainingCents: number; buyerName: string | null; stockAfter?: number | null; paymentId?: number | null }

let token: string;

async function tshirt(): Promise<Product> {
  const res = await api("/products", {
    token,
    body: {
      name: "Maglietta", type: "merchandising", priceCents: 1500, tracksStock: true, lowStockThreshold: 2,
      variants: [{ size: "M", color: "nero" }, { size: "L", color: "nero" }],
    },
  });
  expect(res.status).toBe(201);
  return (await res.json()) as Product;
}
const stock = (variantId: number, kind: "carico" | "rettifica", quantity: number) =>
  api(`/variants/${variantId}/stock`, { token, body: { kind, quantity } });
async function stockOf(productId: number, variantId: number): Promise<number> {
  const list = (await (await api("/products?active=tutti", { token })).json()) as { items: Product[] };
  return list.items.find((p) => p.id === productId)!.variants.find((v) => v.id === variantId)!.stock;
}
async function member(): Promise<number> {
  return ((await (await api("/members", { token, body: { firstName: "A", lastName: "B", joinedOn: "2026-01-01" } })).json()) as { id: number }).id;
}

beforeAll(async () => {
  token = (await loggedInUser()).token;
});

describe("magazzino", () => {
  it("crea un prodotto con varianti, carica e rettifica le scorte", async () => {
    const p = await tshirt();
    expect(p.variants.map((v) => v.label)).toEqual(["M · nero", "L · nero"]);
    const m = p.variants[0]!;
    expect(m.stock).toBe(0);
    await stock(m.id, "carico", 10);
    expect(await stockOf(p.id, m.id)).toBe(10);
    await stock(m.id, "rettifica", 8);
    expect(await stockOf(p.id, m.id)).toBe(8);
    const moves = (await (await api(`/products/${p.id}/movements`, { token })).json()) as { items: { kind: string; quantity: number }[] };
    expect(moves.items.map((x) => [x.kind, x.quantity])).toEqual([["rettifica", -2], ["carico", 10]]);
  });

  it("un prodotto senza varianti indicate ha la variante unica; si aggiungono varianti senza doppioni", async () => {
    const res = await api("/products", { token, body: { name: "Spilla", type: "merchandising", priceCents: 300, tracksStock: true } });
    const p = (await res.json()) as Product;
    expect(p.variants.map((v) => v.label)).toEqual(["Unica"]);
    const added = await api(`/products/${p.id}/variants`, { token, body: { size: "", color: "oro" } });
    expect(((await added.json()) as Product).variants).toHaveLength(2);
    expect(await errorCode(await api(`/products/${p.id}/variants`, { token, body: { size: "", color: "ORO" } }))).toBe("variant_exists");
  });

  it("segnala le scorte basse", async () => {
    const p = await tshirt();
    await stock(p.variants[0]!.id, "carico", 10);
    const low = (await (await api("/stock?low=true", { token })).json()) as { items: { variantId: number }[] };
    expect(low.items.some((i) => i.variantId === p.variants[1]!.id)).toBe(true);
    expect(low.items.some((i) => i.variantId === p.variants[0]!.id)).toBe(false);
  });
});

describe("vendite ai soci con variante", () => {
  it("scala le scorte e le rimette se l'addebito viene annullato", async () => {
    const p = await tshirt();
    const v = p.variants[0]!;
    await stock(v.id, "carico", 5);
    const id = await member();
    const res = await api(`/members/${id}/charges`, { token, body: { productId: p.id, variantId: v.id, quantity: 2 } });
    expect(res.status).toBe(201);
    const sale = (await res.json()) as Sale;
    expect(sale).toMatchObject({ label: "Maglietta (M · nero) ×2", amountCents: 3000, quantity: 2, stockAfter: 3 });
    expect(await stockOf(p.id, v.id)).toBe(3);
    await api(`/dues/${sale.id}/cancel`, { token, body: { reason: "Taglia sbagliata" } });
    expect(await stockOf(p.id, v.id)).toBe(5);
  });

  it("eliminando un addebito mai pagato la merce torna in magazzino e i movimenti spariscono", async () => {
    const p = await tshirt();
    const v = p.variants[1]!;
    await stock(v.id, "carico", 4);
    const id = await member();
    const sale = (await (await api(`/members/${id}/charges`, { token, body: { productId: p.id, variantId: v.id, quantity: 1 } })).json()) as Sale;
    expect(await stockOf(p.id, v.id)).toBe(3);
    expect((await api(`/dues/${sale.id}`, { token, method: "DELETE" })).status).toBe(204);
    expect(await stockOf(p.id, v.id)).toBe(4);
    const moves = await env.DB.prepare("SELECT COUNT(*) AS n FROM stock_movements WHERE due_id = ?1").bind(sale.id).first<{ n: number }>();
    expect(moves!.n).toBe(0);
  });

  it("richiede la variante per i prodotti con scorte e permette di vendere oltre la scorta", async () => {
    const p = await tshirt();
    const id = await member();
    expect((await api(`/members/${id}/charges`, { token, body: { productId: p.id } })).status).toBe(422);
    const res = await api(`/members/${id}/charges`, { token, body: { productId: p.id, variantId: p.variants[1]!.id } });
    expect(((await res.json()) as Sale).stockAfter).toBe(-1);
  });

  it("rifiuta una variante di un altro prodotto", async () => {
    const a = await tshirt();
    const b = await tshirt();
    const id = await member();
    expect((await api(`/members/${id}/charges`, { token, body: { productId: a.id, variantId: b.variants[0]!.id } })).status).toBe(422);
  });
});

describe("vendite a non soci", () => {
  it("pagata subito: nessun nome, incasso registrato, conta tra i non soci", async () => {
    const p = await tshirt();
    await stock(p.variants[0]!.id, "carico", 3);
    const res = await api("/sales", {
      token,
      body: { productId: p.id, variantId: p.variants[0]!.id, buyerName: "Ignorato", payment: { method: "contanti", paidOn: "2026-11-15" } },
    });
    expect(res.status).toBe(201);
    const sale = (await res.json()) as Sale;
    expect(sale).toMatchObject({ remainingCents: 0, buyerName: null, stockAfter: 2 });
    const pay = (await (await api(`/payments/${sale.paymentId}`, { token })).json()) as { memberId: number | null; memberName: string; description: string };
    expect(pay).toMatchObject({ memberId: null, memberName: "Non socio", description: "Maglietta (M · nero)" });
    const income = (await (await api("/reports/income?year=2026", { token })).json()) as { bySource: { nonSoci: number } };
    expect(income.bySource.nonSoci).toBeGreaterThanOrEqual(1500);
  });

  it("da pagare dopo: richiede il nome, compare tra le aperte, e il nome si cancella quando è saldata", async () => {
    const res0 = await api("/products", { token, body: { name: "Workshop", type: "stage", priceCents: 4000 } });
    const workshop = (await res0.json()) as Product;
    expect((await api("/sales", { token, body: { productId: workshop.id } })).status).toBe(422);
    const sale = (await (await api("/sales", { token, body: { productId: workshop.id, buyerName: "Mario" } })).json()) as Sale;
    expect(sale).toMatchObject({ buyerName: "Mario", remainingCents: 4000 });
    const open = (await (await api("/sales", { token })).json()) as { items: Sale[] };
    expect(open.items.some((s) => s.id === sale.id)).toBe(true);
    const status = (await (await api("/reports/status", { token })).json()) as { nonMemberOpenCents: number };
    expect(status.nonMemberOpenCents).toBeGreaterThanOrEqual(4000);

    await api(`/sales/${sale.id}/pay`, { token, body: { method: "bonifico", amountCents: 1000 } });
    let row = await env.DB.prepare("SELECT buyer_name FROM dues WHERE id = ?1").bind(sale.id).first<{ buyer_name: string | null }>();
    expect(row!.buyer_name).toBe("Mario");
    expect(await errorCode(await api(`/sales/${sale.id}/pay`, { token, body: { method: "bonifico", amountCents: 5000 } }))).toBe("amount_exceeds");
    const done = (await (await api(`/sales/${sale.id}/pay`, { token, body: { method: "bonifico" } })).json()) as Sale;
    expect(done).toMatchObject({ remainingCents: 0, buyerName: null });
    row = await env.DB.prepare("SELECT buyer_name FROM dues WHERE id = ?1").bind(sale.id).first<{ buyer_name: string | null }>();
    expect(row!.buyer_name).toBeNull();
  });

  it("annullare il pagamento di una vendita pagata subito annulla la vendita e rimette la merce", async () => {
    const p = await tshirt();
    const v = p.variants[0]!;
    await stock(v.id, "carico", 4);
    const sale = (await (await api("/sales", { token, body: { productId: p.id, variantId: v.id, quantity: 2, payment: { method: "contanti" } } })).json()) as Sale;
    expect(await stockOf(p.id, v.id)).toBe(2);
    await api(`/payments/${sale.paymentId}/void`, { token, body: { reason: "Errore di cassa" } });
    expect(await stockOf(p.id, v.id)).toBe(4);
    const cancelled = await env.DB.prepare("SELECT cancelled_at FROM dues WHERE id = ?1").bind(sale.id).first<{ cancelled_at: string | null }>();
    expect(cancelled!.cancelled_at).not.toBeNull();
  });

  it("annulla una vendita non pagata, ma non una con pagamenti", async () => {
    const p = await tshirt();
    const unpaid = (await (await api("/sales", { token, body: { productId: p.id, variantId: p.variants[0]!.id, buyerName: "Luca" } })).json()) as Sale;
    expect((await api(`/sales/${unpaid.id}/cancel`, { token, body: { reason: "Ci ha ripensato" } })).status).toBe(204);
    const paid = (await (await api("/sales", { token, body: { productId: p.id, variantId: p.variants[0]!.id, payment: { method: "contanti" } } })).json()) as Sale;
    expect(await errorCode(await api(`/sales/${paid.id}/cancel`, { token, body: { reason: "x" } }))).toBe("has_payments");
  });

  it("le vendite a non soci non entrano nei totali dei soci", async () => {
    const p = await tshirt();
    await api("/sales", { token, body: { productId: p.id, variantId: p.variants[0]!.id, buyerName: "Sara" } });
    const status = (await (await api("/reports/status", { token })).json()) as { openChargesTotalCents: number; nonMemberOpenCents: number };
    const members = await env.DB.prepare(
      `SELECT COALESCE(SUM(d.amount_cents - COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
                                                    WHERE a.due_id = d.id AND p.voided_at IS NULL), 0)), 0) AS cents
         FROM dues d JOIN members m ON m.id = d.member_id
        WHERE d.kind = 'prodotto' AND d.cancelled_at IS NULL AND m.status = 'attivo'`,
    ).first<{ cents: number }>();
    expect(status.openChargesTotalCents).toBe(members!.cents);
    expect(status.nonMemberOpenCents).toBeGreaterThan(0);
  });
});

describe("tracciabilità del magazzino", () => {
  it("i movimenti dicono a chi è andata la merce, anche dopo che il nome del non socio è stato cancellato", async () => {
    const p = await tshirt();
    const v = p.variants[0]!;
    await stock(v.id, "carico", 5);
    const memberId = ((await (await api("/members", { token, body: { firstName: "Giulia", lastName: "Ferri", joinedOn: "2026-01-01" } })).json()) as { id: number }).id;
    await api(`/members/${memberId}/charges`, { token, body: { productId: p.id, variantId: v.id } });
    const sale = (await (await api("/sales", { token, body: { productId: p.id, variantId: v.id, buyerName: "Mario" } })).json()) as Sale;
    await api(`/sales/${sale.id}/pay`, { token, body: { method: "contanti" } });

    const moves = (await (await api(`/products/${p.id}/movements`, { token })).json()) as { items: { kind: string; soldTo: string | null; saleId: number | null }[] };
    expect(moves.items.map((m) => [m.kind, m.soldTo])).toEqual([
      ["vendita", "Non socio"],
      ["vendita", "Ferri Giulia"],
      ["carico", null],
    ]);
    expect(moves.items[0]!.saleId).toBe(sale.id);
  });

  it("esporta i movimenti in CSV con destinatario e scorta progressiva", async () => {
    const p = await tshirt();
    const v = p.variants[1]!;
    await stock(v.id, "carico", 4);
    await api("/sales", { token, body: { productId: p.id, variantId: v.id, quantity: 3, payment: { method: "contanti" } } });
    const text = new TextDecoder().decode(await (await api("/export/stock.csv", { token })).arrayBuffer());
    const lines = text.trim().split("\r\n").filter((l) => l.includes(";L;nero;"));
    expect(lines.at(-2)).toMatch(/;Carico;4;4;;/);
    expect(lines.at(-1)).toMatch(/;Vendita;-3;1;Non socio;\d+;/);
    expect(text).toContain("Data;Prodotto;Taglia;Colore;Movimento;Quantità;Scorta dopo;A chi;Vendita n.;Nota;Registrato da");
  });
});

describe("correzioni di magazzino", () => {
  it("corregge taglia e colore ed elimina un carico sbagliato, non una vendita", async () => {
    const p = await tshirt();
    const [m, l] = p.variants;
    expect(await errorCode(await api(`/variants/${m!.id}`, { token, method: "PATCH", body: { size: "L", color: "nero" } }))).toBe("variant_exists");
    const fixed = (await (await api(`/variants/${m!.id}`, { token, method: "PATCH", body: { color: "bianco" } })).json()) as Product;
    expect(fixed.variants.find((v) => v.id === m!.id)).toMatchObject({ size: "M", color: "bianco" });

    await stock(l!.id, "carico", 50);
    const id = await member();
    await api(`/members/${id}/charges`, { token, body: { productId: p.id, variantId: l!.id } });
    const moves = (await env.DB.prepare("SELECT id, kind FROM stock_movements WHERE variant_id = ?1 ORDER BY id").bind(l!.id).all<{ id: number; kind: string }>()).results;
    expect(await stockOf(p.id, l!.id)).toBe(49);
    expect(await errorCode(await api(`/stock-movements/${moves.find((x) => x.kind === "vendita")!.id}`, { token, method: "DELETE" }))).toBe("movement_from_sale");
    expect((await api(`/stock-movements/${moves.find((x) => x.kind === "carico")!.id}`, { token, method: "DELETE" })).status).toBe(200);
    expect(await stockOf(p.id, l!.id)).toBe(-1);
  });
});
