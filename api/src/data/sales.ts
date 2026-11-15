import { dueLabel, variantLabel } from "../domain/dues.ts";
import { auditStatement } from "../lib/audit.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { nowIso } from "../lib/time.ts";

/** Scorta di una variante: somma dei movimenti. */
export const STOCK_SQL = "(SELECT COALESCE(SUM(m.quantity), 0) FROM stock_movements m WHERE m.variant_id = v.id)";

export interface ProductRow {
  id: number;
  name: string;
  type: "stage" | "evento" | "merchandising" | "altro";
  price_cents: number;
  active: number;
  tracks_stock: number;
  low_stock_threshold: number;
}

export interface VariantRow {
  id: number;
  product_id: number;
  size: string;
  color: string;
  active: number;
  stock: number;
}

export const PRODUCT_COLUMNS = "id, name, type, price_cents, active, tracks_stock, low_stock_threshold";

export async function findProduct(db: D1Database, id: number): Promise<ProductRow> {
  const row = await db.prepare(`SELECT ${PRODUCT_COLUMNS} FROM products WHERE id = ?1`).bind(id).first<ProductRow>();
  if (!row) throw notFound("Prodotto non trovato.");
  return row;
}

export async function findVariant(db: D1Database, id: number): Promise<VariantRow> {
  const row = await db
    .prepare(`SELECT v.id, v.product_id, v.size, v.color, v.active, ${STOCK_SQL} AS stock FROM product_variants v WHERE v.id = ?1`)
    .bind(id)
    .first<VariantRow>();
  if (!row) throw notFound("Variante non trovata.");
  return row;
}

export interface SaleInput {
  memberId: number | null;
  buyerName: string | null;
  productId: number;
  variantId?: number;
  quantity: number;
  amountCents?: number;
  reason?: string;
  chargedOn: string;
  userId: number;
}

export interface PreparedSale {
  dueId: number;
  amountCents: number;
  label: string;
  /** Scorta della variante dopo la vendita (null se il prodotto non ha scorte). Può essere negativa. */
  stockAfter: number | null;
  statements: D1PreparedStatement[];
}

/**
 * Prepara l'addebito di un prodotto (a un socio o a un non socio) e lo scarico
 * dal magazzino, da eseguire in un unico batch. L'id della quota è assegnato qui.
 */
export async function prepareSale(db: D1Database, input: SaleInput): Promise<PreparedSale> {
  const product = await findProduct(db, input.productId);
  if (product.active !== 1) throw conflict("product_inactive", "Il prodotto non è più disponibile.");

  let variant: VariantRow | null = null;
  if (product.tracks_stock === 1) {
    if (!input.variantId) throw invalid("Scegli taglia e colore.", [{ field: "variantId", message: "Obbligatorio per i prodotti con scorte." }]);
    variant = await findVariant(db, input.variantId);
    if (variant.product_id !== product.id || variant.active !== 1) {
      throw invalid("Variante non valida per questo prodotto.", [{ field: "variantId", message: "Scegli una variante disponibile." }]);
    }
  } else if (input.variantId) {
    throw invalid("Questo prodotto non ha varianti.", [{ field: "variantId", message: "Non previsto." }]);
  }

  const base = product.price_cents * input.quantity;
  const amount = input.amountCents ?? base;
  if (amount !== base && !input.reason) {
    throw invalid("Indica il motivo del prezzo diverso.", [{ field: "reason", message: "Obbligatorio se il prezzo è diverso dal listino." }]);
  }

  const next = await db.prepare("SELECT COALESCE(MAX(id), 0) + 1 AS id FROM dues").first<{ id: number }>();
  const dueId = next!.id;
  const now = nowIso();
  const vLabel = variant ? variantLabel(variant.size, variant.color) : null;
  const statements = [
    db
      .prepare(
        `INSERT INTO dues (id, member_id, buyer_name, kind, year, product_id, variant_id, quantity, base_amount_cents, amount_cents,
                           adjustment_reason, charged_on, created_at, created_by)
         VALUES (?, ?, ?, 'prodotto', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        dueId, input.memberId, input.buyerName, Number(input.chargedOn.slice(0, 4)), product.id, variant?.id ?? null, input.quantity,
        base, amount, amount === base ? null : input.reason, input.chargedOn, now, input.userId,
      ),
  ];
  if (variant) {
    statements.push(
      db
        .prepare("INSERT INTO stock_movements (variant_id, kind, quantity, due_id, moved_on, created_at, created_by) VALUES (?, 'vendita', ?, ?, ?, ?, ?)")
        .bind(variant.id, -input.quantity, dueId, input.chargedOn, now, input.userId),
    );
  }
  statements.push(
    auditStatement(db, input.userId, "create", "due", dueId, {
      memberId: input.memberId,
      nonMember: input.memberId === null,
      productId: product.id,
      variantId: variant?.id ?? null,
      quantity: input.quantity,
      amountCents: amount,
    }),
  );
  return {
    dueId,
    amountCents: amount,
    label: dueLabel({ kind: "prodotto", year: 0, month: null, productName: product.name, variantLabel: vLabel, quantity: input.quantity }),
    stockAfter: variant ? variant.stock - input.quantity : null,
    statements,
  };
}

/** Rimette in magazzino quanto venduto con una quota annullata (se aveva una variante). */
export function restockStatement(
  db: D1Database,
  due: { id: number; variant_id: number | null; quantity: number },
  userId: number,
  date: string,
): D1PreparedStatement | null {
  if (!due.variant_id) return null;
  return db
    .prepare("INSERT INTO stock_movements (variant_id, kind, quantity, due_id, moved_on, note, created_at, created_by) VALUES (?, 'reso', ?, ?, ?, 'Vendita annullata', ?, ?)")
    .bind(due.variant_id, due.quantity, due.id, date, nowIso(), userId);
}

/** Esegue un batch che usa id assegnati in anticipo: un conflitto significa scrittura concorrente. */
export async function runBatch(db: D1Database, statements: D1PreparedStatement[]) {
  try {
    return await db.batch(statements);
  } catch (e) {
    if (e instanceof Error && /UNIQUE|PRIMARY KEY/.test(e.message)) {
      throw conflict("concurrent_update", "Qualcun altro ha appena registrato un'operazione: riprova.");
    }
    throw e;
  }
}
