import { createRoute, z } from "@hono/zod-openapi";
import { DUE_SELECT, DueSchema, type DueRow, toDue } from "../data/dues.ts";
import { prepareSale, restockStatement, runBatch } from "../data/sales.ts";
import { auditStatement } from "../lib/audit.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

/**
 * Vendite di prodotti ed eventi a chi non è socio. Per minimizzare i dati
 * personali, il nome dell'acquirente si registra solo se paga più tardi e
 * viene cancellato quando la vendita è saldata.
 */

const SaleSchema = DueSchema.extend({
  stockAfter: z.number().int().nullable().optional(),
  paymentId: z.number().int().nullable().optional(),
}).openapi("Sale");

const createSaleRoute = createRoute({
  method: "post",
  path: "/sales",
  tags: ["Vendite a non soci"],
  summary: "Vendita a un non socio, pagata subito o da saldare",
  description: "Con 'payment' la vendita è pagata subito per intero e non si registra alcun nome. Senza, 'buyerName' è obbligatorio.",
  security: bearer,
  request: {
    body: json(
      z.object({
        productId: z.number().int().positive(),
        variantId: z.number().int().positive().optional(),
        quantity: z.number().int().min(1).max(99).default(1),
        amountCents: z.number().int().min(0).max(10_000_000).optional(),
        reason: z.string().trim().max(200).optional(),
        chargedOn: DateSchema.optional(),
        buyerName: z.string().trim().max(80).optional(),
        payment: z.object({ method: z.string().min(1).max(30), paidOn: DateSchema.optional() }).optional(),
      }),
    ),
  },
  responses: { 201: { description: "Vendita registrata", ...json(SaleSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const listRoute = createRoute({
  method: "get",
  path: "/sales",
  tags: ["Vendite a non soci"],
  summary: "Vendite a non soci (le più recenti prima)",
  security: bearer,
  request: { query: z.object({ status: z.enum(["aperte", "tutte"]).default("aperte").openapi({ description: "aperte = da saldare" }) }) },
  responses: { 200: { description: "Vendite", ...json(z.object({ items: z.array(DueSchema) })) }, ...commonErrors },
});

const payRoute = createRoute({
  method: "post",
  path: "/sales/{id}/pay",
  tags: ["Vendite a non soci"],
  summary: "Incassa una vendita a non socio rimasta da saldare",
  security: bearer,
  request: {
    params: IdParam,
    body: json(
      z.object({
        method: z.string().min(1).max(30),
        paidOn: DateSchema.optional(),
        amountCents: z.number().int().positive().max(10_000_000).optional().openapi({ description: "Predefinito: tutto il rimanente" }),
      }),
    ),
  },
  responses: { 200: { description: "Vendita aggiornata", ...json(SaleSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const cancelRoute = createRoute({
  method: "post",
  path: "/sales/{id}/cancel",
  tags: ["Vendite a non soci"],
  summary: "Annulla una vendita non pagata (la merce torna in magazzino)",
  security: bearer,
  request: { params: IdParam, body: json(z.object({ reason: z.string().trim().min(1, "Indica il motivo.").max(200) })) },
  responses: { 204: { description: "Vendita annullata" }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

async function methodId(db: D1Database, code: string): Promise<number> {
  const m = await db.prepare("SELECT id FROM payment_methods WHERE code = ?1 AND active = 1").bind(code).first<{ id: number }>();
  if (!m) throw invalid("Metodo di pagamento non valido.", [{ field: "method", message: "Scegli un metodo attivo." }]);
  return m.id;
}

async function findSale(db: D1Database, id: number): Promise<DueRow> {
  const row = await db.prepare(`${DUE_SELECT} WHERE d.id = ?1 AND d.member_id IS NULL AND d.cancelled_at IS NULL`).bind(id).first<DueRow>();
  if (!row) throw notFound("Vendita non trovata.");
  return row;
}

async function nextPaymentId(db: D1Database): Promise<number> {
  return (await db.prepare("SELECT COALESCE(MAX(id), 0) + 1 AS id FROM payments").first<{ id: number }>())!.id;
}

function paymentStatements(db: D1Database, p: { id: number; dueId: number; amountCents: number; methodId: number; paidOn: string; userId: number }) {
  return [
    db
      .prepare("INSERT INTO payments (id, member_id, paid_on, amount_cents, method_id, recorded_by, created_at) VALUES (?, NULL, ?, ?, ?, ?, ?)")
      .bind(p.id, p.paidOn, p.amountCents, p.methodId, p.userId, nowIso()),
    db.prepare("INSERT INTO payment_allocations (payment_id, due_id, amount_cents) VALUES (?, ?, ?)").bind(p.id, p.dueId, p.amountCents),
    auditStatement(db, p.userId, "create", "payment", p.id, { nonMember: true, dueId: p.dueId, amountCents: p.amountCents }),
  ];
}

export const saleRoutes = createRouter();
saleRoutes.use("/sales", requireAuth);
saleRoutes.use("/sales/*", requireAuth);

saleRoutes
  .openapi(createSaleRoute, async (c) => {
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const buyerName = b.payment ? null : (b.buyerName ?? "").trim();
    if (buyerName === "") {
      throw invalid("Indica il nome di chi pagherà più tardi.", [{ field: "buyerName", message: "Obbligatorio se la vendita non è pagata subito." }]);
    }
    const method = b.payment ? await methodId(db, b.payment.method) : null;
    const chargedOn = b.chargedOn ?? todayIso();
    const sale = await prepareSale(db, {
      memberId: null,
      buyerName,
      productId: b.productId,
      variantId: b.variantId,
      quantity: b.quantity,
      amountCents: b.amountCents,
      reason: b.reason,
      chargedOn,
      userId: me,
    });
    let paymentId: number | null = null;
    const statements = [...sale.statements];
    if (method !== null && sale.amountCents > 0) {
      paymentId = await nextPaymentId(db);
      statements.push(
        ...paymentStatements(db, { id: paymentId, dueId: sale.dueId, amountCents: sale.amountCents, methodId: method, paidOn: b.payment?.paidOn ?? chargedOn, userId: me }),
      );
    }
    await runBatch(db, statements);
    return c.json({ ...toDue(await findSale(db, sale.dueId), todayIso()), stockAfter: sale.stockAfter, paymentId }, 201);
  })
  .openapi(listRoute, async (c) => {
    const { status } = c.req.valid("query");
    const { results } = await c.env.DB.prepare(
      `${DUE_SELECT} WHERE d.member_id IS NULL AND d.cancelled_at IS NULL ORDER BY d.charged_on DESC, d.id DESC LIMIT 300`,
    ).all<DueRow>();
    const today = todayIso();
    const items = results.map((r) => toDue(r, today)).filter((d) => status === "tutte" || d.remainingCents > 0);
    return c.json({ items }, 200);
  })
  .openapi(payRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const sale = await findSale(db, id);
    const remaining = sale.amount_cents - sale.paid_cents;
    if (remaining <= 0) throw conflict("due_already_paid", "La vendita è già saldata.");
    const amount = b.amountCents ?? remaining;
    if (amount > remaining) throw conflict("amount_exceeds", "L'importo supera quanto resta da pagare.");
    const paymentId = await nextPaymentId(db);
    const statements = paymentStatements(db, { id: paymentId, dueId: id, amountCents: amount, methodId: await methodId(db, b.method), paidOn: b.paidOn ?? todayIso(), userId: me });
    // Saldata per intero: il nome dell'acquirente non serve più e viene cancellato.
    if (amount === remaining) statements.push(db.prepare("UPDATE dues SET buyer_name = NULL WHERE id = ?1").bind(id));
    await runBatch(db, statements);
    return c.json({ ...toDue(await findSale(db, id), todayIso()), paymentId }, 200);
  })
  .openapi(cancelRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { reason } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const sale = await findSale(db, id);
    if (sale.paid_cents > 0) throw conflict("has_payments", "La vendita ha dei pagamenti: annulla prima il pagamento.");
    const restock = restockStatement(db, sale, me, todayIso());
    await db.batch([
      db.prepare("UPDATE dues SET cancelled_at = ?1, cancelled_by = ?2, cancel_reason = ?3 WHERE id = ?4").bind(nowIso(), me, reason, id),
      ...(restock ? [restock] : []),
      auditStatement(db, me, "cancel", "due", id, { nonMember: true, reason }),
    ]);
    return c.body(null, 204);
  });
