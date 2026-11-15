import { periodOf } from "../domain/periods.ts";

/**
 * Riepilogo per socio calcolato in SQL (una sola query per tutti i soci),
 * con le stesse regole di domain/dues.ts: sono arretrati le quote associative
 * e mensili con periodo iniziato e non coperte; i prodotti sono a parte.
 * Parametri: ?1 anno corrente, ?2 periodo corrente.
 */
export const SUMMARY_CTE = `
  dues_open AS (
    SELECT d.member_id, d.kind, d.year, d.month,
           d.amount_cents - COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a
                                        JOIN payments p ON p.id = a.payment_id
                                       WHERE a.due_id = d.id AND p.voided_at IS NULL), 0) AS remaining
      FROM dues d WHERE d.cancelled_at IS NULL AND d.member_id IS NOT NULL
  ),
  member_summary AS (
    SELECT member_id,
           SUM(CASE WHEN kind <> 'prodotto' AND remaining > 0
                     AND ((kind = 'annuale' AND year <= ?1) OR (kind = 'mensile' AND year * 12 + month - 1 <= ?2))
                    THEN remaining ELSE 0 END) AS arrears_cents,
           SUM(CASE WHEN kind <> 'prodotto' AND remaining > 0
                     AND ((kind = 'annuale' AND year <= ?1) OR (kind = 'mensile' AND year * 12 + month - 1 <= ?2))
                    THEN 1 ELSE 0 END) AS arrears_count,
           SUM(CASE WHEN kind = 'prodotto' AND remaining > 0 THEN remaining ELSE 0 END) AS open_charges_cents,
           SUM(CASE WHEN kind = 'prodotto' AND remaining > 0 THEN 1 ELSE 0 END) AS open_charges_count
      FROM dues_open GROUP BY member_id
  ),
  member_forms_missing AS (
    SELECT member_id, COUNT(*) AS missing_forms
      FROM member_forms mf JOIN forms f ON f.id = mf.form_id
     WHERE mf.returned_on IS NULL AND f.active = 1
     GROUP BY member_id
  )`;

export function summaryParams(today: string): [number, number] {
  const year = Number(today.slice(0, 4));
  return [year, periodOf(year, Number(today.slice(5, 7)))];
}

export interface SummaryColumns {
  arrears_cents: number | null;
  arrears_count: number | null;
  open_charges_cents: number | null;
  open_charges_count: number | null;
  missing_forms: number | null;
}

export function toSummary(r: SummaryColumns) {
  const arrearsCents = r.arrears_cents ?? 0;
  return {
    arrearsCents,
    arrearsCount: r.arrears_count ?? 0,
    openChargesCents: r.open_charges_cents ?? 0,
    openChargesCount: r.open_charges_count ?? 0,
    missingForms: r.missing_forms ?? 0,
    inRegola: arrearsCents === 0,
  };
}
