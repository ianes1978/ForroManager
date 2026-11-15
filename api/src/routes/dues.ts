import { createRoute, z } from "@hono/zod-openapi";
import { DueSchema, findDue, memberDues, toDue } from "../data/dues.ts";
import { summarize } from "../domain/dues.ts";
import { formatYearMonth, periodOf } from "../domain/periods.ts";
import { auditStatement } from "../lib/audit.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, YearSchema, bearer, commonErrors, createRouter, errors, IdempotencyHeaders, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { idempotent } from "../middleware/idempotency.ts";
import { prepareSale, restockStatement, runBatch } from "../data/sales.ts";

export const SummarySchema = z
  .object({
    arrearsCents: z.number().int(),
    arrearsCount: z.number().int(),
    openChargesCents: z.number().int(),
    openChargesCount: z.number().int(),
    inRegola: z.boolean(),
  })
  .openapi("MemberSummary");

const memberDuesRoute = createRoute({
  method: "get",
  path: "/members/{id}/dues",
  tags: ["Quote"],
  summary: "Quote del socio per un anno, più le voci ancora aperte degli altri anni",
  security: bearer,
  request: { params: IdParam, query: z.object({ year: YearSchema.optional() }) },
  responses: {
    200: {
      description: "Quote e riepilogo",
      ...json(z.object({ year: z.number().int(), items: z.array(DueSchema), summary: SummarySchema })),
    },
    ...commonErrors,
    404: errors[404],
  },
});

const generateRoute = createRoute({
  method: "post",
  path: "/dues/generate",
  tags: ["Quote"],
  summary: "Genera le quote di un anno (associativa) o di un mese per tutti i soci attivi",
  description:
    "Idempotente: le quote già presenti non vengono duplicate. Esclude i soci iscritti dopo il periodo e, per le mensili, quelli sospesi.",
  security: bearer,
  request: {
    body: json(
      z
        .object({ kind: z.enum(["annuale", "mensile"]), year: z.number().int().min(2000).max(2100), month: z.number().int().min(1).max(12).optional() })
        .refine((v) => (v.kind === "mensile") === (v.month !== undefined), { message: "Il mese va indicato solo per le quote mensili.", path: ["month"] }),
    ),
  },
  responses: {
    200: {
      description: "Esito della generazione",
      ...json(
        z
          .object({ created: z.number().int(), alreadyPresent: z.number().int(), suspended: z.number().int() })
          .openapi("GenerateResult"),
      ),
    },
    ...commonErrors,
  },
});

const adjustRoute = createRoute({
  method: "post",
  path: "/dues/{id}/adjust",
  tags: ["Quote"],
  summary: "Cambia l'importo di una singola quota (es. iscrizione a metà mese, agevolazione)",
  description: "Con un importo uguale a quello da tariffa la riduzione viene tolta e il motivo non serve.",
  security: bearer,
  request: {
    params: IdParam,
    body: json(z.object({ amountCents: z.number().int().min(0).max(10_000_000), reason: z.string().trim().max(200).optional() })),
  },
  responses: { 200: { description: "Quota aggiornata", ...json(DueSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const cancelRoute = createRoute({
  method: "post",
  path: "/dues/{id}/cancel",
  tags: ["Quote"],
  summary: "Annulla una quota generata per errore (solo se non ha pagamenti)",
  security: bearer,
  request: { params: IdParam, body: json(z.object({ reason: z.string().trim().min(1, "Indica il motivo.").max(200) })) },
  responses: { 204: { description: "Quota annullata" }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const deleteRoute = createRoute({
  method: "delete",
  path: "/dues/{id}",
  tags: ["Quote"],
  summary: "Elimina una quota mai pagata (creata per errore); se è un prodotto la merce torna in magazzino",
  description: "Se la quota ha ricevuto pagamenti, anche poi annullati, non si elimina: si può solo annullare con un motivo.",
  security: bearer,
  request: { params: IdParam },
  responses: { 204: { description: "Quota eliminata" }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const chargeRoute = createRoute({
  method: "post",
  path: "/members/{id}/charges",
  tags: ["Quote"],
  summary: "Addebita un prodotto o evento al socio (da pagare subito o più tardi)",
  security: bearer,
  middleware: [idempotent] as const,
  request: {
    headers: IdempotencyHeaders,
    params: IdParam,
    body: json(
      z.object({
        productId: z.number().int().positive(),
        variantId: z.number().int().positive().optional().openapi({ description: "Obbligatoria per i prodotti con scorte" }),
        quantity: z.number().int().min(1).max(99).default(1),
        amountCents: z.number().int().min(0).max(10_000_000).optional().openapi({ description: "Totale; se diverso da prezzo × quantità serve il motivo" }),
        reason: z.string().trim().max(200).optional(),
        chargedOn: DateSchema.optional(),
      }),
    ),
  },
  responses: {
    201: {
      description: "Addebito creato",
      ...json(DueSchema.extend({ stockAfter: z.number().int().nullable().openapi({ description: "Scorta rimasta della variante; negativa se si è venduto oltre la scorta" }) }).openapi("Charge")),
    },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

/** Data limite (esclusa) per l'iscrizione: il socio deve essere iscritto prima della fine del periodo. */
function periodEnd(kind: "annuale" | "mensile", year: number, month?: number): string {
  if (kind === "annuale") return `${year + 1}-01-01`;
  const next = periodOf(year, month!) + 1;
  return `${formatYearMonth(next)}-01`;
}

export const dueRoutes = createRouter();
dueRoutes.use("/dues/*", requireAuth);
dueRoutes.use("/members/*", requireAuth);

dueRoutes
  .openapi(memberDuesRoute, async (c) => {
    const { id } = c.req.valid("param");
    const today = todayIso();
    const year = c.req.valid("query").year ?? Number(today.slice(0, 4));
    const db = c.env.DB;
    const member = await db.prepare("SELECT id FROM members WHERE id = ?1").bind(id).first();
    if (!member) throw notFound("Socio non trovato.");
    const all = (await memberDues(db, id)).map((r) => toDue(r, today));
    const summary = summarize(all, today);
    // L'anno richiesto per intero, più le voci aperte degli altri anni (arretrati e prodotti da saldare).
    const items = all.filter((d) => d.year === year || (d.remainingCents > 0 && d.status !== "futura"));
    return c.json({ year, items, summary }, 200);
  })
  .openapi(generateRoute, async (c) => {
    const { kind, year, month } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const end = periodEnd(kind, year, month);
    const categoryColumn = kind === "annuale" ? "annual_category_id" : "monthly_category_id";
    const monthly = kind === "mensile";
    const period = monthly ? periodOf(year, month!) : null;
    // Parametri comuni a tutte le query: ?1 anno, ?2 fine periodo (esclusa), ?3 periodo mensile.
    const bindCommon = (stmt: D1PreparedStatement, ...extra: unknown[]) =>
      monthly ? stmt.bind(year, end, period, ...extra) : stmt.bind(year, end, ...extra);
    const extraBase = monthly ? 4 : 3;
    const suspendedSql = `EXISTS (SELECT 1 FROM member_suspensions s WHERE s.member_id = m.id AND s.cancelled_at IS NULL
                                     AND ?3 BETWEEN s.from_period AND s.to_period)`;

    const missing = await db
      .prepare(
        `SELECT DISTINCT c.name FROM members m
           JOIN fee_categories c ON c.id = m.${categoryColumn}
           LEFT JOIN fee_rates r ON r.category_id = c.id AND r.year = ?1
          WHERE m.status = 'attivo' AND m.joined_on < ?2 AND r.id IS NULL`,
      )
      .bind(year, end)
      .all<{ name: string }>();
    if (missing.results.length) {
      throw invalid(
        `Prima fissa l'importo ${year} per: ${missing.results.map((r) => `${kind} ${r.name.toLowerCase()}`).join(", ")}.`,
        missing.results.map((r) => ({ field: "rate", message: r.name })),
      );
    }

    const counts = await bindCommon(
      db.prepare(
        `SELECT COUNT(*) AS candidates,
                COALESCE(SUM(CASE WHEN ${monthly ? suspendedSql : "0"} THEN 1 ELSE 0 END), 0) AS suspended
           FROM members m WHERE m.status = 'attivo' AND m.joined_on < ?2 AND ?1 = ?1`,
      ),
    ).first<{ candidates: number; suspended: number }>();

    const n = (k: number) => `?${extraBase + k}`;
    const now = nowIso();
    const insert = await bindCommon(
      db.prepare(
        `INSERT INTO dues (member_id, kind, year, month, category_id, base_amount_cents, amount_cents, charged_on, created_at, created_by)
         SELECT m.id, ${n(0)}, ?1, ${n(1)}, m.${categoryColumn}, r.amount_cents, r.amount_cents, ${n(2)}, ${n(3)}, ${n(4)}
           FROM members m JOIN fee_rates r ON r.category_id = m.${categoryColumn} AND r.year = ?1
          WHERE m.status = 'attivo' AND m.joined_on < ?2
            ${monthly ? `AND NOT ${suspendedSql}` : ""}
            AND NOT EXISTS (SELECT 1 FROM dues d WHERE d.member_id = m.id AND d.kind = ${n(0)} AND d.year = ?1
                               AND COALESCE(d.month, 0) = COALESCE(${n(1)}, 0) AND d.cancelled_at IS NULL)`,
      ),
      kind,
      month ?? null,
      todayIso(),
      now,
      me,
    ).run();
    const created = insert.meta.changes ?? 0;
    const suspended = counts?.suspended ?? 0;
    const alreadyPresent = (counts?.candidates ?? 0) - suspended - created;
    await auditStatement(db, me, "generate", "dues", null, { kind, year, month: month ?? null, created }).run();
    return c.json({ created, alreadyPresent, suspended }, 200);
  })
  .openapi(adjustRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { amountCents, reason } = c.req.valid("json");
    const db = c.env.DB;
    const due = await findDue(db, id);
    const restoring = amountCents === due.base_amount_cents;
    if (!restoring && !reason) {
      throw invalid("Indica il motivo della modifica.", [{ field: "reason", message: "Obbligatorio se l'importo è diverso dalla tariffa." }]);
    }
    if (amountCents < due.paid_cents) {
      throw conflict("below_paid", "L'importo non può essere inferiore a quanto già pagato.");
    }
    await db.batch([
      db.prepare("UPDATE dues SET amount_cents = ?1, adjustment_reason = ?2 WHERE id = ?3").bind(amountCents, restoring ? null : reason, id),
      auditStatement(db, c.get("user").id, "update", "due", id, {
        memberId: due.member_id,
        before: { amountCents: due.amount_cents, reason: due.adjustment_reason },
        after: { amountCents, reason: restoring ? null : reason },
      }),
    ]);
    return c.json(toDue(await findDue(db, id), todayIso()), 200);
  })
  .openapi(cancelRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { reason } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const due = await findDue(db, id);
    if (due.paid_cents > 0) throw conflict("has_payments", "La quota ha dei pagamenti: annulla prima i pagamenti.");
    const restock = restockStatement(db, due, me, todayIso());
    await db.batch([
      db.prepare("UPDATE dues SET cancelled_at = ?1, cancelled_by = ?2, cancel_reason = ?3 WHERE id = ?4").bind(nowIso(), me, reason, id),
      ...(restock ? [restock] : []),
      auditStatement(db, me, "cancel", "due", id, { memberId: due.member_id, reason }),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const due = await db
      .prepare("SELECT id, member_id, kind, year, month, amount_cents, cancelled_at FROM dues WHERE id = ?1")
      .bind(id)
      .first<{ id: number; member_id: number | null; kind: string; year: number; month: number | null; amount_cents: number; cancelled_at: string | null }>();
    if (!due) throw notFound("Quota non trovata.");
    if (await db.prepare("SELECT 1 FROM payment_allocations WHERE due_id = ?1 LIMIT 1").bind(id).first()) {
      throw conflict("has_payments", "La quota ha ricevuto dei pagamenti (anche annullati): non si può eliminare, ma puoi annullarla indicando il motivo.");
    }
    // I movimenti di magazzino della vendita spariscono con lei: la scorta torna com'era.
    await db.batch([
      db.prepare("DELETE FROM stock_movements WHERE due_id = ?1").bind(id),
      db.prepare("DELETE FROM dues WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "due", id, {
        memberId: due.member_id, kind: due.kind, year: due.year, month: due.month, amountCents: due.amount_cents, wasCancelled: due.cancelled_at !== null,
      }),
    ]);
    return c.body(null, 204);
  })
  .openapi(chargeRoute, async (c) => {
    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const member = await db.prepare("SELECT status FROM members WHERE id = ?1").bind(id).first<{ status: string }>();
    if (!member) throw notFound("Socio non trovato.");
    if (member.status !== "attivo") throw conflict("member_ceased", "Il socio è cessato.");
    const sale = await prepareSale(db, {
      memberId: id,
      buyerName: null,
      productId: body.productId,
      variantId: body.variantId,
      quantity: body.quantity,
      amountCents: body.amountCents,
      reason: body.reason,
      chargedOn: body.chargedOn ?? todayIso(),
      userId: me,
    });
    await runBatch(db, sale.statements);
    return c.json({ ...toDue(await findDue(db, sale.dueId), todayIso()), stockAfter: sale.stockAfter }, 201);
  });
