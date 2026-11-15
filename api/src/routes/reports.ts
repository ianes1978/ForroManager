import { createRoute, z } from "@hono/zod-openapi";
import { SUMMARY_CTE, type SummaryColumns, summaryParams, toSummary } from "../data/summary.ts";
import { YearSchema, bearer, commonErrors, createRouter, json } from "../lib/http.ts";
import { todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

const statusRoute = createRoute({
  method: "get",
  path: "/reports/status",
  tags: ["Riepilogo"],
  summary: "Chi è in regola e chi no (soci attivi, alla data odierna)",
  security: bearer,
  responses: {
    200: {
      description: "Situazione dei soci",
      ...json(
        z
          .object({
            activeMembers: z.number().int(),
            inRegola: z.number().int(),
            notInRegola: z.number().int(),
            arrearsTotalCents: z.number().int(),
            openChargesTotalCents: z.number().int(),
            nonMemberOpenCents: z.number().int().openapi({ description: "Vendite a non soci ancora da saldare" }),
            nonMemberOpenCount: z.number().int(),
            members: z.array(
              z.object({
                id: z.number().int(),
                name: z.string(),
                arrearsCents: z.number().int(),
                arrearsCount: z.number().int(),
                openChargesCents: z.number().int(),
              }),
            ),
          })
          .openapi("StatusReport"),
      ),
    },
    ...commonErrors,
  },
});

const incomeRoute = createRoute({
  method: "get",
  path: "/reports/income",
  tags: ["Riepilogo"],
  summary: "Incassi dell'anno per mese, per metodo e per voce (pagamenti non annullati)",
  security: bearer,
  request: { query: z.object({ year: YearSchema.optional() }) },
  responses: {
    200: {
      description: "Incassi",
      ...json(
        z
          .object({
            year: z.number().int(),
            totalCents: z.number().int(),
            byMonth: z.array(z.number().int()).length(12).openapi({ description: "Gennaio..dicembre, per data di pagamento" }),
            byMethod: z.array(z.object({ code: z.string(), label: z.string(), cents: z.number().int() })),
            byKind: z.object({ annuale: z.number().int(), mensile: z.number().int(), periodo: z.number().int(), prodotto: z.number().int() }),
            bySource: z.object({ soci: z.number().int(), nonSoci: z.number().int() }).openapi({ description: "Incassi da soci e da vendite a non soci" }),
          })
          .openapi("IncomeReport"),
      ),
    },
    ...commonErrors,
  },
});

export const reportRoutes = createRouter();
reportRoutes.use("/reports/*", requireAuth);

reportRoutes
  .openapi(statusRoute, async (c) => {
    const { results } = await c.env.DB.prepare(
      `WITH ${SUMMARY_CTE}
       SELECT m.id, m.first_name, m.last_name, s.arrears_cents, s.arrears_count, s.open_charges_cents, s.open_charges_count, NULL AS missing_forms
         FROM members m LEFT JOIN member_summary s ON s.member_id = m.id
        WHERE m.status = 'attivo'
        ORDER BY COALESCE(s.arrears_cents, 0) DESC, m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`,
    )
      .bind(...summaryParams(todayIso()))
      .all<SummaryColumns & { id: number; first_name: string; last_name: string }>();
    const rows = results.map((r) => ({ ...toSummary(r), id: r.id, name: `${r.last_name} ${r.first_name}` }));
    const open = await c.env.DB.prepare(
      `SELECT COALESCE(SUM(rest), 0) AS cents, COUNT(*) AS n FROM (
         SELECT d.amount_cents - COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
                                            WHERE a.due_id = d.id AND p.voided_at IS NULL), 0) AS rest
           FROM dues d WHERE d.member_id IS NULL AND d.cancelled_at IS NULL) WHERE rest > 0`,
    ).first<{ cents: number; n: number }>();
    const notInRegola = rows.filter((r) => !r.inRegola);
    return c.json(
      {
        activeMembers: rows.length,
        inRegola: rows.length - notInRegola.length,
        notInRegola: notInRegola.length,
        arrearsTotalCents: rows.reduce((s, r) => s + r.arrearsCents, 0),
        openChargesTotalCents: rows.reduce((s, r) => s + r.openChargesCents, 0),
        nonMemberOpenCents: open?.cents ?? 0,
        nonMemberOpenCount: open?.n ?? 0,
        members: rows
          .filter((r) => !r.inRegola || r.openChargesCents > 0)
          .map((r) => ({ id: r.id, name: r.name, arrearsCents: r.arrearsCents, arrearsCount: r.arrearsCount, openChargesCents: r.openChargesCents })),
      },
      200,
    );
  })
  .openapi(incomeRoute, async (c) => {
    const year = c.req.valid("query").year ?? Number(todayIso().slice(0, 4));
    const db = c.env.DB;
    const range = [`${year}-01-01`, `${year}-12-31`];
    const [byMonth, byMethod, byKind, bySource] = await db.batch([
      db
        .prepare(
          `SELECT CAST(substr(paid_on, 6, 2) AS INTEGER) AS month, SUM(amount_cents) AS cents
             FROM payments WHERE voided_at IS NULL AND paid_on BETWEEN ?1 AND ?2 GROUP BY month`,
        )
        .bind(...range),
      db
        .prepare(
          `SELECT pm.code, pm.label, COALESCE(SUM(p.amount_cents), 0) AS cents
             FROM payment_methods pm
             LEFT JOIN payments p ON p.method_id = pm.id AND p.voided_at IS NULL AND p.paid_on BETWEEN ?1 AND ?2
            GROUP BY pm.id ORDER BY pm.sort_order`,
        )
        .bind(...range),
      db
        .prepare(
          `SELECT d.kind, SUM(a.amount_cents) AS cents
             FROM payment_allocations a JOIN payments p ON p.id = a.payment_id JOIN dues d ON d.id = a.due_id
            WHERE p.voided_at IS NULL AND p.paid_on BETWEEN ?1 AND ?2 GROUP BY d.kind`,
        )
        .bind(...range),
      db
        .prepare(
          `SELECT COALESCE(SUM(CASE WHEN member_id IS NOT NULL THEN amount_cents END), 0) AS soci,
                  COALESCE(SUM(CASE WHEN member_id IS NULL THEN amount_cents END), 0) AS non_soci
             FROM payments WHERE voided_at IS NULL AND paid_on BETWEEN ?1 AND ?2`,
        )
        .bind(...range),
    ]);
    const source = (bySource!.results as { soci: number; non_soci: number }[])[0] ?? { soci: 0, non_soci: 0 };
    const months = Array.from({ length: 12 }, () => 0);
    for (const r of byMonth!.results as { month: number; cents: number }[]) months[r.month - 1] = r.cents;
    const kinds = { annuale: 0, mensile: 0, periodo: 0, prodotto: 0 };
    for (const r of byKind!.results as { kind: keyof typeof kinds; cents: number }[]) kinds[r.kind] = r.cents;
    return c.json(
      {
        year,
        totalCents: months.reduce((a, b) => a + b, 0),
        byMonth: months,
        byMethod: (byMethod!.results as { code: string; label: string; cents: number }[]).map((r) => ({ code: r.code, label: r.label, cents: r.cents })),
        byKind: kinds,
        bySource: { soci: source.soci, nonSoci: source.non_soci },
      },
      200,
    );
  });
