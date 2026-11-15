import { createRoute, z } from "@hono/zod-openapi";
import { SUMMARY_CTE, type SummaryColumns, summaryParams, toSummary } from "../data/summary.ts";
import { VARIANT_LABEL_SQL } from "../data/dues.ts";
import { euro, toCsv } from "../lib/csv.ts";
import { DateSchema, bearer, commonErrors, createRouter } from "../lib/http.ts";
import { todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { describeAllocations } from "./payments.ts";
import { SOLD_TO_SQL } from "./products.ts";

const csvResponse = (description: string) => ({ description, content: { "text/csv": { schema: z.string() } } });

const membersCsvRoute = createRoute({
  method: "get", path: "/export/members.csv", tags: ["Esportazione"], summary: "Soci in CSV, con situazione dei pagamenti", security: bearer,
  request: { query: z.object({ status: z.enum(["attivo", "cessato", "tutti"]).default("tutti") }) },
  responses: { 200: csvResponse("File CSV"), ...commonErrors },
});

const paymentsCsvRoute = createRoute({
  method: "get", path: "/export/payments.csv", tags: ["Esportazione"], summary: "Pagamenti in CSV (compresi gli annullati, segnalati)", security: bearer,
  request: { query: z.object({ from: DateSchema.optional(), to: DateSchema.optional() }) },
  responses: { 200: csvResponse("File CSV"), ...commonErrors },
});

function csv(body: string, filename: string): Response {
  return new Response(body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${filename}"`,
      // Dati personali: niente cache intermedie.
      "Cache-Control": "no-store",
    },
  });
}

const stockCsvRoute = createRoute({
  method: "get", path: "/export/stock.csv", tags: ["Esportazione"], security: bearer,
  summary: "Movimenti di magazzino in CSV (carichi, vendite con destinatario, resi, rettifiche)",
  request: { query: z.object({ from: DateSchema.optional(), to: DateSchema.optional() }) },
  responses: { 200: csvResponse("File CSV"), ...commonErrors },
});

export const exportRoutes = createRouter();
exportRoutes.use("/export/*", requireAuth);

exportRoutes
  .openapi(membersCsvRoute, async (c) => {
    const { status } = c.req.valid("query");
    const today = todayIso();
    const { results } = await c.env.DB.prepare(
      `WITH ${SUMMARY_CTE}
       SELECT m.id, m.first_name, m.last_name, m.email, m.phone, m.joined_on, m.status, m.ceased_on, m.notes,
              ac.name AS annual_name, s.arrears_cents, s.arrears_count, s.open_charges_cents, s.open_charges_count, f.missing_forms
         FROM members m JOIN fee_categories ac ON ac.id = m.annual_category_id
         LEFT JOIN member_summary s ON s.member_id = m.id
         LEFT JOIN member_forms_missing f ON f.member_id = m.id
        ${status === "tutti" ? "" : "WHERE m.status = ?3"}
        ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`,
    )
      .bind(...summaryParams(today), ...(status === "tutti" ? [] : [status]))
      .all<SummaryColumns & Record<string, string | number | null>>();
    const body = toCsv(
      ["ID", "Cognome", "Nome", "Email", "Telefono", "Iscritto dal", "Stato", "Cessato il", "Quota associativa", "In regola", "Arretrati (€)", "Prodotti da saldare (€)", "Moduli da riavere", "Note"],
      results.map((r) => {
        const s = toSummary(r);
        return [r.id, r.last_name, r.first_name, r.email, r.phone, r.joined_on, r.status, r.ceased_on, r.annual_name, s.inRegola ? "sì" : "no", euro(s.arrearsCents), euro(s.openChargesCents), s.missingForms, r.notes];
      }),
    );
    return csv(body, `soci_${today}.csv`) as never;
  })
  .openapi(stockCsvRoute, async (c) => {
    const { from, to } = c.req.valid("query");
    const { results } = await c.env.DB.prepare(
      `SELECT m.moved_on, p.name AS product, v.size, v.color, m.kind, m.quantity, ${SOLD_TO_SQL} AS sold_to,
              m.due_id, m.note, u.name AS user_name,
              (SELECT SUM(m2.quantity) FROM stock_movements m2 WHERE m2.variant_id = m.variant_id AND m2.id <= m.id) AS stock_after
         FROM stock_movements m JOIN product_variants v ON v.id = m.variant_id JOIN products p ON p.id = v.product_id
         JOIN users u ON u.id = m.created_by
         LEFT JOIN dues d ON d.id = m.due_id LEFT JOIN members mb ON mb.id = d.member_id
        WHERE m.moved_on BETWEEN ?1 AND ?2
        ORDER BY m.moved_on, m.id`,
    )
      .bind(from ?? "0000-01-01", to ?? "9999-12-31")
      .all<Record<string, string | number | null>>();
    const kinds: Record<string, string> = { carico: "Carico", vendita: "Vendita", reso: "Reso", rettifica: "Rettifica" };
    const body = toCsv(
      ["Data", "Prodotto", "Taglia", "Colore", "Movimento", "Quantità", "Scorta dopo", "A chi", "Vendita n.", "Nota", "Registrato da"],
      results.map((r) => [r.moved_on, r.product, r.size, r.color, kinds[r.kind as string], r.quantity, r.stock_after, r.sold_to, r.due_id, r.note, r.user_name]),
    );
    return csv(body, `magazzino_${from ?? "inizio"}_${to ?? todayIso()}.csv`) as never;
  })
  .openapi(paymentsCsvRoute, async (c) => {
    const { from, to } = c.req.valid("query");
    const db = c.env.DB;
    const range = [from ?? "0000-01-01", to ?? "9999-12-31"];
    const [payments, allocs] = await db.batch([
      db
        .prepare(
          `SELECT p.id, p.paid_on, m.last_name, m.first_name, p.amount_cents, pm.label AS method, p.note, u.name AS recorded_by,
                  p.voided_at, p.void_reason
             FROM payments p LEFT JOIN members m ON m.id = p.member_id JOIN payment_methods pm ON pm.id = p.method_id JOIN users u ON u.id = p.recorded_by
            WHERE p.paid_on BETWEEN ?1 AND ?2 ORDER BY p.paid_on, p.id`,
        )
        .bind(...range),
      db
        .prepare(
          `SELECT a.payment_id, d.kind, d.year, d.month, pr.name AS product_name, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity
             FROM payment_allocations a JOIN payments p ON p.id = a.payment_id JOIN dues d ON d.id = a.due_id
             LEFT JOIN products pr ON pr.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id
            WHERE p.paid_on BETWEEN ?1 AND ?2 ORDER BY a.id`,
        )
        .bind(...range),
    ]);
    const byPayment = new Map<number, Parameters<typeof describeAllocations>[0]>();
    for (const a of allocs!.results as { payment_id: number; kind: "annuale" | "mensile" | "prodotto"; year: number; month: number | null; product_name: string | null; variant_label: string | null; quantity: number }[]) {
      byPayment.set(a.payment_id, [...(byPayment.get(a.payment_id) ?? []), a]);
    }
    const body = toCsv(
      ["ID", "Data", "Cognome", "Nome", "Importo (€)", "Metodo", "Voci", "Nota", "Registrato da", "Annullato", "Motivo annullamento"],
      (payments!.results as Record<string, string | number | null>[]).map((p) => [
        p.id, p.paid_on, p.last_name ?? "Non socio", p.first_name, euro(p.amount_cents as number), p.method,
        describeAllocations(byPayment.get(p.id as number) ?? []), p.note, p.recorded_by, p.voided_at ? "sì" : "no", p.void_reason,
      ]),
    );
    return csv(body, `pagamenti_${from ?? "inizio"}_${to ?? todayIso()}.csv`) as never;
  });
