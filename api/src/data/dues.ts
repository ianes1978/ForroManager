import { z } from "@hono/zod-openapi";
import { type DueKind, dueLabel, dueStatus, remainingCents } from "../domain/dues.ts";

/** Espressione SQL per l'etichetta della variante (v = product_variants), null se unica. */
export const VARIANT_LABEL_SQL = `NULLIF(TRIM(COALESCE(v.size, '') || CASE WHEN COALESCE(v.size, '') <> '' AND COALESCE(v.color, '') <> '' THEN ' · ' ELSE '' END || COALESCE(v.color, '')), '')`;
import { notFound } from "../lib/errors.ts";

export interface DueRow {
  id: number;
  member_id: number | null;
  buyer_name: string | null;
  kind: DueKind;
  year: number;
  month: number | null;
  category_id: number | null;
  product_id: number | null;
  product_name: string | null;
  variant_id: number | null;
  variant_label: string | null;
  quantity: number;
  base_amount_cents: number;
  amount_cents: number;
  adjustment_reason: string | null;
  charged_on: string;
  paid_cents: number;
}

const PAID_SUBQUERY = `COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a
                                  JOIN payments py ON py.id = a.payment_id
                                 WHERE a.due_id = d.id AND py.voided_at IS NULL), 0)`;

export const DUE_SELECT = `
  SELECT d.id, d.member_id, d.buyer_name, d.kind, d.year, d.month, d.category_id, d.product_id, p.name AS product_name,
         d.variant_id, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity,
         d.base_amount_cents, d.amount_cents, d.adjustment_reason, d.charged_on,
         ${PAID_SUBQUERY} AS paid_cents
    FROM dues d LEFT JOIN products p ON p.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id`;

export const DueSchema = z
  .object({
    id: z.number().int(),
    kind: z.enum(["annuale", "mensile", "prodotto"]),
    year: z.number().int(),
    month: z.number().int().nullable(),
    label: z.string().openapi({ example: "Mensile luglio 2026" }),
    categoryId: z.number().int().nullable(),
    productId: z.number().int().nullable(),
    variantId: z.number().int().nullable(),
    variantLabel: z.string().nullable().openapi({ example: "M · nero" }),
    quantity: z.number().int(),
    buyerName: z.string().nullable().openapi({ description: "Solo per vendite a non soci da saldare" }),
    baseAmountCents: z.number().int(),
    amountCents: z.number().int(),
    adjustmentReason: z.string().nullable(),
    paidCents: z.number().int(),
    remainingCents: z.number().int(),
    status: z.enum(["pagata", "parziale", "da_pagare", "futura"]),
    chargedOn: z.string(),
  })
  .openapi("Due");

export type Due = z.infer<typeof DueSchema>;

export function toDue(r: DueRow, today: string): Due {
  const like = { kind: r.kind, year: r.year, month: r.month, amountCents: r.amount_cents, paidCents: r.paid_cents };
  return {
    id: r.id,
    kind: r.kind,
    year: r.year,
    month: r.month,
    label: dueLabel({ kind: r.kind, year: r.year, month: r.month, productName: r.product_name, variantLabel: r.variant_label, quantity: r.quantity }),
    categoryId: r.category_id,
    productId: r.product_id,
    variantId: r.variant_id,
    variantLabel: r.variant_label,
    quantity: r.quantity,
    buyerName: r.buyer_name,
    baseAmountCents: r.base_amount_cents,
    amountCents: r.amount_cents,
    adjustmentReason: r.adjustment_reason,
    paidCents: r.paid_cents,
    remainingCents: remainingCents(like),
    status: dueStatus(like, today),
    chargedOn: r.charged_on,
  };
}

/** Tutte le quote non annullate di un socio, con il pagato. */
export async function memberDues(db: D1Database, memberId: number): Promise<DueRow[]> {
  const { results } = await db
    .prepare(
      `${DUE_SELECT} WHERE d.member_id = ?1 AND d.cancelled_at IS NULL
        ORDER BY d.year, CASE d.kind WHEN 'annuale' THEN 0 WHEN 'mensile' THEN 1 ELSE 2 END, d.month, d.charged_on, d.id`,
    )
    .bind(memberId)
    .all<DueRow>();
  return results;
}

export async function findDue(db: D1Database, id: number): Promise<DueRow> {
  const row = await db.prepare(`${DUE_SELECT} WHERE d.id = ?1 AND d.cancelled_at IS NULL`).bind(id).first<DueRow>();
  if (!row) throw notFound("Quota non trovata.");
  return row;
}
