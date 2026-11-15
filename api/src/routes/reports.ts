import { createRoute, z } from "@hono/zod-openapi";
import { PERIOD_LABEL_SQL, VARIANT_LABEL_SQL } from "../data/dues.ts";
import { SUMMARY_CTE, type SummaryColumns, summaryParams, toSummary } from "../data/summary.ts";
import { type DueKind, dueLabel, dueStatus, remainingCents } from "../domain/dues.ts";
import { YearSchema, bearer, commonErrors, createRouter, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { describeAllocations } from "./payments.ts";

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

const FullRowSchema = z.record(z.string(), z.union([z.string(), z.number(), z.boolean(), z.null()]));

const fullRoute = createRoute({
  method: "get",
  path: "/reports/full",
  tags: ["Riepilogo"],
  summary: "Dati completi per il report Excel (di un anno o di tutto lo storico)",
  description: "Soci con situazione, quote e iscrizioni, pagamenti con le voci, vendite e movimenti di magazzino. Importi in centesimi.",
  security: bearer,
  request: { query: z.object({ year: YearSchema.optional().openapi({ description: "Senza anno: tutto lo storico" }) }) },
  responses: {
    200: {
      description: "Dati del report",
      ...json(
        z
          .object({
            year: z.number().int().nullable(),
            generatedAt: z.string(),
            members: z.array(FullRowSchema),
            dues: z.array(FullRowSchema),
            payments: z.array(FullRowSchema),
            sales: z.array(FullRowSchema),
            stock: z.array(FullRowSchema),
          })
          .openapi("FullReport"),
      ),
    },
    ...commonErrors,
  },
});

export const reportRoutes = createRouter();
reportRoutes.use("/reports/*", requireAuth);

reportRoutes
  .openapi(fullRoute, async (c) => {
    const { year } = c.req.valid("query");
    const db = c.env.DB;
    const today = todayIso();
    const from = year ? `${year}-01-01` : "0000-01-01";
    const to = year ? `${year}-12-31` : "9999-12-31";
    const PAID = `COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
                             WHERE a.due_id = d.id AND p.voided_at IS NULL), 0)`;
    const [members, dues, payments, allocs, stock] = await db.batch([
      db
        .prepare(
          `WITH ${SUMMARY_CTE}
           SELECT m.id, m.last_name, m.first_name, m.email, m.phone, m.joined_on, m.status, m.ceased_on, m.notes,
                  ac.name AS annual_category, s.arrears_cents, s.arrears_count, s.open_charges_cents, s.open_charges_count, f.missing_forms
             FROM members m JOIN fee_categories ac ON ac.id = m.annual_category_id
             LEFT JOIN member_summary s ON s.member_id = m.id LEFT JOIN member_forms_missing f ON f.member_id = m.id
            ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`,
        )
        .bind(...summaryParams(today)),
      db
        .prepare(
          `SELECT d.id, d.kind, d.year, d.month, d.charged_on, d.member_id, m.last_name, m.first_name, d.buyer_name,
                  ${PERIOD_LABEL_SQL} AS period_label, pr.name AS product_name, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity,
                  d.base_amount_cents, d.amount_cents, d.adjustment_reason, ${PAID} AS paid_cents
             FROM dues d LEFT JOIN members m ON m.id = d.member_id
             LEFT JOIN products pr ON pr.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id
             LEFT JOIN course_periods cp ON cp.id = d.course_period_id LEFT JOIN courses co ON co.id = cp.course_id
            WHERE d.cancelled_at IS NULL AND (?1 IS NULL OR d.year = ?1)
            ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE, d.year, d.month, d.id`,
        )
        .bind(year ?? null),
      db
        .prepare(
          `SELECT p.id, p.paid_on, p.member_id, m.last_name, m.first_name, p.amount_cents, pm.label AS method, p.note,
                  u.name AS recorded_by, p.voided_at, p.void_reason
             FROM payments p LEFT JOIN members m ON m.id = p.member_id JOIN payment_methods pm ON pm.id = p.method_id
             JOIN users u ON u.id = p.recorded_by
            WHERE p.paid_on BETWEEN ?1 AND ?2 ORDER BY p.paid_on, p.id`,
        )
        .bind(from, to),
      db
        .prepare(
          `SELECT a.payment_id, d.kind, d.year, d.month, pr.name AS product_name, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity,
                  ${PERIOD_LABEL_SQL} AS period_label
             FROM payment_allocations a JOIN payments p ON p.id = a.payment_id JOIN dues d ON d.id = a.due_id
             LEFT JOIN products pr ON pr.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id
             LEFT JOIN course_periods cp ON cp.id = d.course_period_id LEFT JOIN courses co ON co.id = cp.course_id
            WHERE p.paid_on BETWEEN ?1 AND ?2 ORDER BY a.id`,
        )
        .bind(from, to),
      db
        .prepare(
          `SELECT m.moved_on, pr.name AS product, ${VARIANT_LABEL_SQL} AS variant, m.kind, m.quantity, m.note, u.name AS recorded_by,
                  CASE WHEN m.due_id IS NULL THEN NULL WHEN d.member_id IS NULL THEN 'Non socio' ELSE mb.last_name || ' ' || mb.first_name END AS sold_to
             FROM stock_movements m JOIN product_variants v ON v.id = m.variant_id JOIN products pr ON pr.id = v.product_id
             JOIN users u ON u.id = m.created_by LEFT JOIN dues d ON d.id = m.due_id LEFT JOIN members mb ON mb.id = d.member_id
            WHERE m.moved_on BETWEEN ?1 AND ?2 ORDER BY m.moved_on, m.id`,
        )
        .bind(from, to),
    ]);

    type Row = Record<string, string | number | null>;
    type Out = Record<string, string | number | boolean | null>;
    /** Righe del report: i campi mancanti diventano null. */
    const out = (o: Record<string, unknown>): Out =>
      Object.fromEntries(Object.entries(o).map(([k, v]) => [k, (v ?? null) as string | number | boolean | null]));
    const rows = (r: D1Result | undefined) => (r?.results ?? []) as Row[];
    const byPayment = new Map<number, Parameters<typeof describeAllocations>[0]>();
    for (const a of rows(allocs) as unknown as (Parameters<typeof describeAllocations>[0][number] & { payment_id: number })[]) {
      byPayment.set(a.payment_id, [...(byPayment.get(a.payment_id) ?? []), a]);
    }
    const name = (r: Row) => (r.member_id === null ? "Non socio" : `${r.last_name} ${r.first_name}`);
    const label = (r: Row) =>
      dueLabel({
        kind: r.kind as DueKind, year: r.year as number, month: r.month as number | null, productName: r.product_name as string | null,
        variantLabel: r.variant_label as string | null, quantity: r.quantity as number, periodLabel: r.period_label as string | null,
      });
    const allDues = rows(dues).map((r) => {
      const like = { kind: r.kind as DueKind, year: r.year as number, month: r.month as number | null, amountCents: r.amount_cents as number, paidCents: r.paid_cents as number };
      return { r, like, status: dueStatus(like, today), remaining: remainingCents(like) };
    });
    return c.json(
      {
        year: year ?? null,
        generatedAt: nowIso(),
        members: rows(members).map((r) => {
          const s = toSummary(r as unknown as SummaryColumns);
          return out({
            cognome: r.last_name, nome: r.first_name, email: r.email, telefono: r.phone, iscrittoDal: r.joined_on, stato: r.status,
            cessatoIl: r.ceased_on, tessera: r.annual_category, inRegola: s.inRegola, arretratiCents: s.arrearsCents,
            prodottiDaSaldareCents: s.openChargesCents, moduliDaRiavere: s.missingForms, note: r.notes,
          });
        }),
        dues: allDues
          .filter((x) => x.r.kind !== "prodotto")
          .map(({ r, status, remaining }) => out({
            socio: name(r), voce: label(r), tipo: r.kind, anno: r.year, importoCents: r.amount_cents, tariffaCents: r.base_amount_cents,
            pagatoCents: r.paid_cents, daPagareCents: remaining, stato: status, motivoRiduzione: r.adjustment_reason,
          })),
        payments: rows(payments).map((r) => out({
          data: r.paid_on, socio: name(r), voci: describeAllocations(byPayment.get(r.id as number) ?? []), metodo: r.method,
          importoCents: r.amount_cents, nota: r.note, registratoDa: r.recorded_by, annullato: r.voided_at !== null, motivoAnnullamento: r.void_reason,
        })),
        sales: allDues
          .filter((x) => x.r.kind === "prodotto")
          .map(({ r, remaining }) => out({
            data: r.charged_on, acquirente: r.member_id === null ? (r.buyer_name ? `Non socio (${r.buyer_name})` : "Non socio") : `${r.last_name} ${r.first_name}`,
            prodotto: r.product_name, variante: r.variant_label, quantita: r.quantity, importoCents: r.amount_cents, pagatoCents: r.paid_cents,
            daSaldareCents: remaining,
          })),
        stock: rows(stock).map((r) => out({
          data: r.moved_on, prodotto: r.product, variante: r.variant ?? "Unica", movimento: r.kind, quantita: r.quantity, aChi: r.sold_to,
          nota: r.note, registratoDa: r.recorded_by,
        })),
      },
      200,
    );
  })
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
