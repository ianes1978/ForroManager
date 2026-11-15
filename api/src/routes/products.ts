import { createRoute, z } from "@hono/zod-openapi";
import { auditStatement } from "../lib/audit.ts";
import { notFound } from "../lib/errors.ts";
import { IdParam, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { nowIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

const TypeSchema = z.enum(["stage", "evento", "merchandising", "altro"]);

export const ProductSchema = z
  .object({ id: z.number().int(), name: z.string(), type: TypeSchema, priceCents: z.number().int(), active: z.boolean() })
  .openapi("Product");

interface ProductRow { id: number; name: string; type: z.infer<typeof TypeSchema>; price_cents: number; active: number }
const toProduct = (r: ProductRow) => ({ id: r.id, name: r.name, type: r.type, priceCents: r.price_cents, active: r.active === 1 });
const COLS = "id, name, type, price_cents, active";

const PriceSchema = z.number().int("L'importo va indicato in centesimi.").min(0).max(10_000_000);

const listRoute = createRoute({
  method: "get",
  path: "/products",
  tags: ["Prodotti ed eventi"],
  summary: "Catalogo di prodotti ed eventi",
  security: bearer,
  request: { query: z.object({ active: z.enum(["true", "false", "tutti"]).default("true") }) },
  responses: { 200: { description: "Prodotti", ...json(z.object({ items: z.array(ProductSchema) })) }, ...commonErrors },
});

const createProductRoute = createRoute({
  method: "post",
  path: "/products",
  tags: ["Prodotti ed eventi"],
  summary: "Nuovo prodotto o evento",
  security: bearer,
  request: {
    body: json(z.object({ name: z.string().trim().min(1, "Il nome è obbligatorio.").max(100), type: TypeSchema, priceCents: PriceSchema })),
  },
  responses: { 201: { description: "Creato", ...json(ProductSchema) }, ...commonErrors },
});

const updateProductRoute = createRoute({
  method: "patch",
  path: "/products/{id}",
  tags: ["Prodotti ed eventi"],
  summary: "Modifica o disattiva un prodotto",
  security: bearer,
  request: {
    params: IdParam,
    body: json(
      z
        .object({ name: z.string().trim().min(1).max(100).optional(), type: TypeSchema.optional(), priceCents: PriceSchema.optional(), active: z.boolean().optional() })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Aggiornato", ...json(ProductSchema) }, ...commonErrors, 404: errors[404] },
});

export async function findProduct(db: D1Database, id: number): Promise<ProductRow> {
  const row = await db.prepare(`SELECT ${COLS} FROM products WHERE id = ?1`).bind(id).first<ProductRow>();
  if (!row) throw notFound("Prodotto non trovato.");
  return row;
}

export const productRoutes = createRouter();
productRoutes.use("/products", requireAuth);
productRoutes.use("/products/*", requireAuth);

productRoutes
  .openapi(listRoute, async (c) => {
    const { active } = c.req.valid("query");
    const filter = active === "tutti" ? "" : `WHERE active = ${active === "true" ? 1 : 0}`;
    const { results } = await c.env.DB.prepare(`SELECT ${COLS} FROM products ${filter} ORDER BY name COLLATE NOCASE`).all<ProductRow>();
    return c.json({ items: results.map(toProduct) }, 200);
  })
  .openapi(createProductRoute, async (c) => {
    const { name, type, priceCents } = c.req.valid("json");
    const db = c.env.DB;
    const now = nowIso();
    const row = await db
      .prepare(`INSERT INTO products (name, type, price_cents, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4) RETURNING ${COLS}`)
      .bind(name, type, priceCents, now)
      .first<ProductRow>();
    await auditStatement(db, c.get("user").id, "create", "product", row!.id, { name, type, priceCents }).run();
    return c.json(toProduct(row!), 201);
  })
  .openapi(updateProductRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const before = await findProduct(db, id);
    await db.batch([
      db
        .prepare(
          `UPDATE products SET name = COALESCE(?1, name), type = COALESCE(?2, type), price_cents = COALESCE(?3, price_cents),
                               active = COALESCE(?4, active), updated_at = ?5 WHERE id = ?6`,
        )
        .bind(b.name ?? null, b.type ?? null, b.priceCents ?? null, b.active === undefined ? null : Number(b.active), nowIso(), id),
      auditStatement(db, c.get("user").id, "update", "product", id, { before: toProduct(before), changes: b }),
    ]);
    return c.json(toProduct(await findProduct(db, id)), 200);
  });
