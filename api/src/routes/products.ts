import { createRoute, z } from "@hono/zod-openapi";
import { PRODUCT_COLUMNS, type ProductRow, STOCK_SQL, type VariantRow, findProduct, findVariant } from "../data/sales.ts";
import { variantLabel } from "../domain/dues.ts";
import { auditStatement } from "../lib/audit.ts";
import { assertNotModified } from "../lib/concurrency.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, bearer, commonErrors, createRouter, errors, IfMatchHeaders, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

export { findProduct };

const TypeSchema = z.enum(["stage", "evento", "merchandising", "altro"]);
const PriceSchema = z.number().int("L'importo va indicato in centesimi.").min(0).max(10_000_000);
const VariantInputSchema = z.object({
  size: z.string().trim().max(20).default(""),
  color: z.string().trim().max(30).default(""),
});

export const VariantSchema = z
  .object({
    id: z.number().int(),
    size: z.string(),
    color: z.string(),
    label: z.string().openapi({ example: "M · nero" }),
    active: z.boolean(),
    stock: z.number().int().openapi({ description: "Pezzi disponibili (può essere negativa se si è venduto oltre la scorta)" }),
    low: z.boolean().openapi({ description: "Scorta pari o inferiore alla soglia del prodotto" }),
  })
  .openapi("ProductVariant");

export const ProductSchema = z
  .object({
    id: z.number().int(),
    name: z.string(),
    type: TypeSchema,
    priceCents: z.number().int(),
    active: z.boolean(),
    tracksStock: z.boolean(),
    lowStockThreshold: z.number().int(),
    variants: z.array(VariantSchema),
    updatedAt: z.string(),
  })
  .openapi("Product");

const toVariant = (v: VariantRow, threshold: number) => ({
  id: v.id,
  size: v.size,
  color: v.color,
  label: variantLabel(v.size, v.color) ?? "Unica",
  active: v.active === 1,
  stock: v.stock,
  low: v.active === 1 && v.stock <= threshold,
});

const toProduct = (r: ProductRow, variants: VariantRow[]) => ({
  id: r.id,
  name: r.name,
  type: r.type,
  priceCents: r.price_cents,
  active: r.active === 1,
  tracksStock: r.tracks_stock === 1,
  lowStockThreshold: r.low_stock_threshold,
  updatedAt: r.updated_at,
  variants: r.tracks_stock === 1 ? variants.filter((v) => v.product_id === r.id).map((v) => toVariant(v, r.low_stock_threshold)) : [],
});

/** A chi è andata la merce di un movimento (d = dues, mb = members). */
export const SOLD_TO_SQL = `CASE WHEN m.due_id IS NULL THEN NULL WHEN d.member_id IS NULL THEN 'Non socio' ELSE mb.last_name || ' ' || mb.first_name END`;

const VARIANT_SELECT = `SELECT v.id, v.product_id, v.size, v.color, v.active, ${STOCK_SQL} AS stock FROM product_variants v`;

async function productWithVariants(db: D1Database, id: number) {
  const product = await findProduct(db, id);
  const { results } = await db.prepare(`${VARIANT_SELECT} WHERE v.product_id = ?1 ORDER BY v.id`).bind(id).all<VariantRow>();
  return toProduct(product, results);
}

// --- Rotte -------------------------------------------------------------------
const listRoute = createRoute({
  method: "get", path: "/products", tags: ["Prodotti ed eventi"], summary: "Catalogo con varianti e scorte", security: bearer,
  request: { query: z.object({ active: z.enum(["true", "false", "tutti"]).default("true") }) },
  responses: { 200: { description: "Prodotti", ...json(z.object({ items: z.array(ProductSchema) })) }, ...commonErrors },
});

const createProductRoute = createRoute({
  method: "post", path: "/products", tags: ["Prodotti ed eventi"], summary: "Nuovo prodotto o evento", security: bearer,
  description: "Con tracksStock il prodotto ha scorte di magazzino per variante; senza varianti indicate ne viene creata una unica.",
  request: {
    body: json(
      z.object({
        name: z.string().trim().min(1, "Il nome è obbligatorio.").max(100),
        type: TypeSchema,
        priceCents: PriceSchema,
        tracksStock: z.boolean().default(false),
        lowStockThreshold: z.number().int().min(0).max(1000).default(2),
        variants: z.array(VariantInputSchema).max(60).default([]),
      }),
    ),
  },
  responses: { 201: { description: "Creato", ...json(ProductSchema) }, ...commonErrors, 409: errors[409] },
});

const updateProductRoute = createRoute({
  method: "patch", path: "/products/{id}", tags: ["Prodotti ed eventi"], summary: "Modifica o disattiva un prodotto", security: bearer,
  request: {
    headers: IfMatchHeaders,
    params: IdParam,
    body: json(
      z
        .object({
          name: z.string().trim().min(1).max(100).optional(),
          type: TypeSchema.optional(),
          priceCents: PriceSchema.optional(),
          active: z.boolean().optional(),
          tracksStock: z.boolean().optional(),
          lowStockThreshold: z.number().int().min(0).max(1000).optional(),
        })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404] },
});

const addVariantRoute = createRoute({
  method: "post", path: "/products/{id}/variants", tags: ["Magazzino"], summary: "Aggiunge una variante (taglia, colore)", security: bearer,
  request: { params: IdParam, body: json(VariantInputSchema) },
  responses: { 201: { description: "Prodotto aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const VariantIdParam = z.object({ variantId: z.coerce.number().int().positive().openapi({ param: { name: "variantId", in: "path" } }) });

const updateVariantRoute = createRoute({
  method: "patch", path: "/variants/{variantId}", tags: ["Magazzino"], summary: "Corregge taglia e colore, o disattiva/riattiva una variante", security: bearer,
  request: {
    params: VariantIdParam,
    body: json(
      z
        .object({ active: z.boolean().optional(), size: z.string().trim().max(20).optional(), color: z.string().trim().max(30).optional() })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Prodotto aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const deleteMovementRoute = createRoute({
  method: "delete", path: "/stock-movements/{movementId}", tags: ["Magazzino"], security: bearer,
  summary: "Elimina un carico o una rettifica registrati per errore (le vendite si correggono dalla quota)",
  request: { params: z.object({ movementId: z.coerce.number().int().positive().openapi({ param: { name: "movementId", in: "path" } }) }) },
  responses: { 200: { description: "Prodotto aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const stockRoute = createRoute({
  method: "post", path: "/variants/{variantId}/stock", tags: ["Magazzino"], security: bearer,
  summary: "Carico di merce o rettifica dopo un conteggio",
  description: "carico: aggiunge 'quantity' pezzi. rettifica: porta la scorta esattamente a 'quantity' (pezzi contati).",
  request: {
    params: VariantIdParam,
    body: json(
      z.object({
        kind: z.enum(["carico", "rettifica"]),
        quantity: z.number().int().min(0).max(100_000),
        note: z.string().trim().max(200).optional(),
        movedOn: DateSchema.optional(),
      }),
    ),
  },
  responses: { 200: { description: "Prodotto aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404] },
});

const MovementSchema = z
  .object({
    id: z.number().int(),
    variantLabel: z.string(),
    kind: z.enum(["carico", "vendita", "reso", "rettifica"]),
    quantity: z.number().int(),
    movedOn: z.string(),
    note: z.string().nullable(),
    userName: z.string(),
    soldTo: z.string().nullable().openapi({ description: "Per vendite e resi: nome del socio oppure \"Non socio\"", example: "Non socio" }),
    saleId: z.number().int().nullable().openapi({ description: "Vendita collegata (quota del prodotto)" }),
  })
  .openapi("StockMovement");

const movementsRoute = createRoute({
  method: "get", path: "/products/{id}/movements", tags: ["Magazzino"], summary: "Movimenti di magazzino del prodotto (più recenti prima)", security: bearer,
  request: { params: IdParam },
  responses: { 200: { description: "Movimenti", ...json(z.object({ items: z.array(MovementSchema) })) }, ...commonErrors, 404: errors[404] },
});

const stockListRoute = createRoute({
  method: "get", path: "/stock", tags: ["Magazzino"], summary: "Scorte di tutte le varianti attive", security: bearer,
  request: { query: z.object({ low: z.enum(["true", "false"]).default("false").openapi({ description: "Solo scorte basse o esaurite" }) }) },
  responses: {
    200: {
      description: "Scorte",
      ...json(
        z.object({
          items: z.array(
            z.object({ productId: z.number().int(), productName: z.string(), variantId: z.number().int(), label: z.string(), stock: z.number().int(), low: z.boolean() }),
          ),
        }),
      ),
    },
    ...commonErrors,
  },
});

export const productRoutes = createRouter();
for (const path of ["/products", "/products/*", "/variants/*", "/stock", "/stock-movements/*"]) productRoutes.use(path, requireAuth);

productRoutes
  .openapi(listRoute, async (c) => {
    const { active } = c.req.valid("query");
    const filter = active === "tutti" ? "" : `WHERE active = ${active === "true" ? 1 : 0}`;
    const db = c.env.DB;
    const [products, variants] = await db.batch([
      db.prepare(`SELECT ${PRODUCT_COLUMNS} FROM products ${filter} ORDER BY name COLLATE NOCASE`),
      db.prepare(`${VARIANT_SELECT} ORDER BY v.id`),
    ]);
    const vs = variants!.results as unknown as VariantRow[];
    return c.json({ items: (products!.results as unknown as ProductRow[]).map((p) => toProduct(p, vs)) }, 200);
  })
  .openapi(createProductRoute, async (c) => {
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const now = nowIso();
    const row = await db
      .prepare(
        `INSERT INTO products (name, type, price_cents, tracks_stock, low_stock_threshold, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6) RETURNING id`,
      )
      .bind(b.name, b.type, b.priceCents, Number(b.tracksStock), b.lowStockThreshold, now)
      .first<{ id: number }>();
    const variants = b.tracksStock ? (b.variants.length ? b.variants : [{ size: "", color: "" }]) : [];
    const keys = new Set(variants.map((v) => `${v.size.toLowerCase()}|${v.color.toLowerCase()}`));
    if (keys.size !== variants.length) throw invalid("Ci sono varianti ripetute.", [{ field: "variants", message: "Ogni combinazione di taglia e colore una sola volta." }]);
    await db.batch([
      ...variants.map((v) =>
        db.prepare("INSERT INTO product_variants (product_id, size, color, created_at) VALUES (?1, ?2, ?3, ?4)").bind(row!.id, v.size, v.color, now),
      ),
      auditStatement(db, me, "create", "product", row!.id, { name: b.name, type: b.type, priceCents: b.priceCents, tracksStock: b.tracksStock, variants: variants.length }),
    ]);
    return c.json(await productWithVariants(db, row!.id), 201);
  })
  .openapi(updateProductRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const before = await findProduct(db, id);
    await assertNotModified(c, before.updated_at, { entity: "product", entityId: id });
    const statements = [
      db
        .prepare(
          `UPDATE products SET name = COALESCE(?1, name), type = COALESCE(?2, type), price_cents = COALESCE(?3, price_cents),
                               active = COALESCE(?4, active), tracks_stock = COALESCE(?5, tracks_stock),
                               low_stock_threshold = COALESCE(?6, low_stock_threshold), updated_at = ?7 WHERE id = ?8`,
        )
        .bind(
          b.name ?? null, b.type ?? null, b.priceCents ?? null, b.active === undefined ? null : Number(b.active),
          b.tracksStock === undefined ? null : Number(b.tracksStock), b.lowStockThreshold ?? null, nowIso(), id,
        ),
      auditStatement(db, c.get("user").id, "update", "product", id, { before: { name: before.name, priceCents: before.price_cents, active: before.active === 1 }, changes: b }),
    ];
    // Attivando le scorte su un prodotto senza varianti si crea la variante unica.
    if (b.tracksStock === true) {
      statements.push(
        db
          .prepare(
            `INSERT INTO product_variants (product_id, size, color, created_at)
             SELECT ?1, '', '', ?2 WHERE NOT EXISTS (SELECT 1 FROM product_variants WHERE product_id = ?1)`,
          )
          .bind(id, nowIso()),
      );
    }
    await db.batch(statements);
    return c.json(await productWithVariants(db, id), 200);
  })
  .openapi(addVariantRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { size, color } = c.req.valid("json");
    const db = c.env.DB;
    const product = await findProduct(db, id);
    if (product.tracks_stock !== 1) throw conflict("stock_disabled", "Attiva prima le scorte di magazzino per questo prodotto.");
    const exists = await db
      .prepare("SELECT 1 FROM product_variants WHERE product_id = ?1 AND size = ?2 COLLATE NOCASE AND color = ?3 COLLATE NOCASE")
      .bind(id, size, color)
      .first();
    if (exists) throw conflict("variant_exists", "Questa variante esiste già.");
    const row = await db
      .prepare("INSERT INTO product_variants (product_id, size, color, created_at) VALUES (?1, ?2, ?3, ?4) RETURNING id")
      .bind(id, size, color, nowIso())
      .first<{ id: number }>();
    await auditStatement(db, c.get("user").id, "create", "variant", row!.id, { productId: id, size, color }).run();
    return c.json(await productWithVariants(db, id), 201);
  })
  .openapi(updateVariantRoute, async (c) => {
    const { variantId } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const v = await findVariant(db, variantId);
    const before = await db.prepare("SELECT size, color, active FROM product_variants WHERE id = ?1").bind(variantId).first<{ size: string; color: string; active: number }>();
    const size = b.size ?? before!.size;
    const color = b.color ?? before!.color;
    if (b.size !== undefined || b.color !== undefined) {
      const exists = await db
        .prepare("SELECT 1 FROM product_variants WHERE product_id = ?1 AND size = ?2 COLLATE NOCASE AND color = ?3 COLLATE NOCASE AND id <> ?4")
        .bind(v.product_id, size, color, variantId)
        .first();
      if (exists) throw conflict("variant_exists", "Esiste già una variante con questa taglia e questo colore.");
    }
    await db.batch([
      db.prepare("UPDATE product_variants SET size = ?1, color = ?2, active = COALESCE(?3, active) WHERE id = ?4")
        .bind(size, color, b.active === undefined ? null : Number(b.active), variantId),
      auditStatement(db, c.get("user").id, "update", "variant", variantId, { before: { size: before!.size, color: before!.color, active: before!.active === 1 }, changes: b }),
    ]);
    return c.json(await productWithVariants(db, v.product_id), 200);
  })
  .openapi(deleteMovementRoute, async (c) => {
    const { movementId } = c.req.valid("param");
    const db = c.env.DB;
    const m = await db
      .prepare("SELECT s.kind, s.quantity, s.variant_id, v.product_id FROM stock_movements s JOIN product_variants v ON v.id = s.variant_id WHERE s.id = ?1")
      .bind(movementId)
      .first<{ kind: string; quantity: number; variant_id: number; product_id: number }>();
    if (!m) throw notFound("Movimento non trovato.");
    if (m.kind !== "carico" && m.kind !== "rettifica") {
      throw conflict("movement_from_sale", "Questo movimento viene da una vendita: per correggerlo elimina o annulla la vendita dalla scheda del socio o dalle vendite.");
    }
    await db.batch([
      db.prepare("DELETE FROM stock_movements WHERE id = ?1").bind(movementId),
      auditStatement(db, c.get("user").id, "delete", "stock_movement", movementId, { variantId: m.variant_id, kind: m.kind, quantity: m.quantity }),
    ]);
    return c.json(await productWithVariants(db, m.product_id), 200);
  })
  .openapi(stockRoute, async (c) => {
    const { variantId } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const v = await findVariant(db, variantId);
    const delta = b.kind === "carico" ? b.quantity : b.quantity - v.stock;
    if (b.kind === "carico" && b.quantity === 0) throw invalid("Indica quanti pezzi carichi.", [{ field: "quantity", message: "Deve essere maggiore di zero." }]);
    if (delta !== 0) {
      await db.batch([
        db
          .prepare("INSERT INTO stock_movements (variant_id, kind, quantity, moved_on, note, created_at, created_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
          .bind(variantId, b.kind, delta, b.movedOn ?? todayIso(), b.note || null, nowIso(), me),
        auditStatement(db, me, "update", "stock", variantId, { kind: b.kind, before: v.stock, after: v.stock + delta }),
      ]);
    }
    return c.json(await productWithVariants(db, v.product_id), 200);
  })
  .openapi(movementsRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    await findProduct(db, id);
    const { results } = await db
      .prepare(
        `SELECT m.id, v.size, v.color, m.kind, m.quantity, m.moved_on, m.note, u.name AS user_name, m.due_id,
                ${SOLD_TO_SQL} AS sold_to
           FROM stock_movements m JOIN product_variants v ON v.id = m.variant_id JOIN users u ON u.id = m.created_by
           LEFT JOIN dues d ON d.id = m.due_id LEFT JOIN members mb ON mb.id = d.member_id
          WHERE v.product_id = ?1 ORDER BY m.id DESC LIMIT 200`,
      )
      .bind(id)
      .all<{ id: number; size: string; color: string; kind: "carico" | "vendita" | "reso" | "rettifica"; quantity: number; moved_on: string; note: string | null; user_name: string; due_id: number | null; sold_to: string | null }>();
    return c.json(
      {
        items: results.map((m) => ({
          id: m.id, variantLabel: variantLabel(m.size, m.color) ?? "Unica", kind: m.kind, quantity: m.quantity, movedOn: m.moved_on, note: m.note, userName: m.user_name,
          soldTo: m.sold_to, saleId: m.due_id,
        })),
      },
      200,
    );
  })
  .openapi(stockListRoute, async (c) => {
    const onlyLow = c.req.valid("query").low === "true";
    const { results } = await c.env.DB.prepare(
      `SELECT p.id AS product_id, p.name, p.low_stock_threshold, v.id, v.size, v.color, ${STOCK_SQL} AS stock
         FROM product_variants v JOIN products p ON p.id = v.product_id
        WHERE p.active = 1 AND p.tracks_stock = 1 AND v.active = 1
        ORDER BY p.name COLLATE NOCASE, v.id`,
    ).all<{ product_id: number; name: string; low_stock_threshold: number; id: number; size: string; color: string; stock: number }>();
    const items = results
      .map((r) => ({ productId: r.product_id, productName: r.name, variantId: r.id, label: variantLabel(r.size, r.color) ?? "Unica", stock: r.stock, low: r.stock <= r.low_stock_threshold }))
      .filter((r) => !onlyLow || r.low);
    return c.json({ items }, 200);
  });
