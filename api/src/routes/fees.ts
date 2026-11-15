import { createRoute, z } from "@hono/zod-openapi";
import { auditStatement } from "../lib/audit.ts";
import { assertNotModified } from "../lib/concurrency.ts";
import { conflict, notFound } from "../lib/errors.ts";
import { IdParam, YearSchema, bearer, commonErrors, createRouter, errors, IfMatchHeaders, json } from "../lib/http.ts";
import { nowIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

const KindSchema = z.enum(["annuale", "mensile", "pacchetto"]);

const FeeSchema = z
  .object({
    categoryId: z.number().int(),
    kind: KindSchema,
    name: z.string(),
    months: z.number().int().nullable().openapi({ description: "Solo per i pacchetti: mesi coperti" }),
    active: z.boolean(),
    year: z.number().int(),
    amountCents: z.number().int().nullable().openapi({ description: "Null se l'importo per l'anno non è ancora stato fissato" }),
    updatedAt: z.string().nullable().openapi({ description: 'Versione per If-Match ("none" se null)' }),
  })
  .openapi("Fee");

const CategorySchema = z
  .object({ id: z.number().int(), kind: KindSchema, name: z.string(), months: z.number().int().nullable(), active: z.boolean() })
  .openapi("FeeCategory");

interface CategoryRow {
  id: number;
  kind: "annuale" | "mensile" | "pacchetto";
  name: string;
  months: number | null;
  active: number;
}

const toCategory = (r: CategoryRow) => ({ id: r.id, kind: r.kind, name: r.name, months: r.months, active: r.active === 1 });

const listRoute = createRoute({
  method: "get",
  path: "/fees",
  tags: ["Tariffe"],
  summary: "Tariffe di un anno, per categoria",
  security: bearer,
  request: { query: z.object({ year: YearSchema }) },
  responses: { 200: { description: "Tariffe", ...json(z.object({ items: z.array(FeeSchema) })) }, ...commonErrors },
});

const createCategoryRoute = createRoute({
  method: "post",
  path: "/fee-categories",
  tags: ["Tariffe"],
  summary: "Crea una categoria di tariffa (es. Associativa ridotta, Pacchetto 3 mesi)",
  security: bearer,
  request: {
    body: json(
      z
        .object({
          kind: KindSchema,
          name: z.string().trim().min(1, "Il nome è obbligatorio.").max(60),
          months: z.number().int().min(2).max(12).optional(),
        })
        .refine((v) => (v.kind === "pacchetto") === (v.months !== undefined), {
          message: "Indica i mesi solo per i pacchetti (da 2 a 12).",
          path: ["months"],
        }),
    ),
  },
  responses: { 201: { description: "Categoria creata", ...json(CategorySchema) }, ...commonErrors, 409: errors[409] },
});

const updateCategoryRoute = createRoute({
  method: "patch",
  path: "/fee-categories/{id}",
  tags: ["Tariffe"],
  summary: "Rinomina o disattiva una categoria",
  security: bearer,
  request: {
    params: IdParam,
    body: json(
      z
        .object({ name: z.string().trim().min(1).max(60).optional(), active: z.boolean().optional() })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: {
    200: { description: "Categoria aggiornata", ...json(CategorySchema) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

const setRateRoute = createRoute({
  method: "put",
  path: "/fees/{year}/{categoryId}",
  tags: ["Tariffe"],
  summary: "Fissa l'importo di una categoria per l'anno",
  description:
    "Con applyToUnpaid aggiorna anche le quote già generate di quell'anno e categoria che non hanno pagamenti e non hanno riduzioni personali.",
  security: bearer,
  request: {
    headers: IfMatchHeaders,
    params: z.object({
      year: YearSchema.openapi({ param: { name: "year", in: "path" } }),
      categoryId: z.coerce.number().int().positive().openapi({ param: { name: "categoryId", in: "path" } }),
    }),
    body: json(
      z.object({
        amountCents: z.number().int("L'importo va indicato in centesimi.").min(0).max(10_000_000),
        applyToUnpaid: z.boolean().default(false),
      }),
    ),
  },
  responses: {
    200: { description: "Importo aggiornato", ...json(z.object({ fee: FeeSchema, updatedDues: z.number().int() })) },
    ...commonErrors,
    404: errors[404],
  },
});

async function findCategory(db: D1Database, id: number): Promise<CategoryRow> {
  const row = await db.prepare("SELECT id, kind, name, months, active FROM fee_categories WHERE id = ?1").bind(id).first<CategoryRow>();
  if (!row) throw notFound("Categoria di tariffa non trovata.");
  return row;
}

async function feeOf(db: D1Database, categoryId: number, year: number) {
  const row = await db
    .prepare(
      `SELECT c.id, c.kind, c.name, c.months, c.active, r.amount_cents, r.updated_at
         FROM fee_categories c LEFT JOIN fee_rates r ON r.category_id = c.id AND r.year = ?2
        WHERE c.id = ?1`,
    )
    .bind(categoryId, year)
    .first<CategoryRow & { amount_cents: number | null }>();
  return toFee(row!, year);
}

const toFee = (r: CategoryRow & { amount_cents: number | null; updated_at?: string | null }, year: number) => ({
  categoryId: r.id,
  kind: r.kind,
  name: r.name,
  months: r.months,
  active: r.active === 1,
  year,
  amountCents: r.amount_cents,
  updatedAt: r.updated_at ?? null,
});

export const feeRoutes = createRouter();
feeRoutes.use("/fees", requireAuth);
feeRoutes.use("/fees/*", requireAuth);
feeRoutes.use("/fee-categories", requireAuth);
feeRoutes.use("/fee-categories/*", requireAuth);

feeRoutes
  .openapi(listRoute, async (c) => {
    const { year } = c.req.valid("query");
    const { results } = await c.env.DB.prepare(
      `SELECT c.id, c.kind, c.name, c.months, c.active, r.amount_cents, r.updated_at
         FROM fee_categories c LEFT JOIN fee_rates r ON r.category_id = c.id AND r.year = ?1
        ORDER BY CASE c.kind WHEN 'annuale' THEN 0 WHEN 'mensile' THEN 1 ELSE 2 END, c.id`,
    )
      .bind(year)
      .all<CategoryRow & { amount_cents: number | null }>();
    return c.json({ items: results.map((r) => toFee(r, year)) }, 200);
  })
  .openapi(createCategoryRoute, async (c) => {
    const { kind, name, months } = c.req.valid("json");
    const db = c.env.DB;
    const exists = await db.prepare("SELECT id FROM fee_categories WHERE kind = ?1 AND name = ?2 COLLATE NOCASE").bind(kind, name).first();
    if (exists) throw conflict("category_exists", "Esiste già una tariffa con questo nome.");
    const row = await db
      .prepare("INSERT INTO fee_categories (kind, name, months, created_at) VALUES (?1, ?2, ?3, ?4) RETURNING id, kind, name, months, active")
      .bind(kind, name, months ?? null, nowIso())
      .first<CategoryRow>();
    await auditStatement(db, c.get("user").id, "create", "fee_category", row!.id, { kind, name, months: months ?? null }).run();
    return c.json(toCategory(row!), 201);
  })
  .openapi(updateCategoryRoute, async (c) => {
    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const before = await findCategory(db, id);
    if (body.name && body.name.toLowerCase() !== before.name.toLowerCase()) {
      const exists = await db
        .prepare("SELECT id FROM fee_categories WHERE kind = ?1 AND name = ?2 COLLATE NOCASE AND id <> ?3")
        .bind(before.kind, body.name, id)
        .first();
      if (exists) throw conflict("category_exists", "Esiste già una tariffa con questo nome.");
    }
    await db.batch([
      db
        .prepare("UPDATE fee_categories SET name = COALESCE(?1, name), active = COALESCE(?2, active) WHERE id = ?3")
        .bind(body.name ?? null, body.active === undefined ? null : Number(body.active), id),
      auditStatement(db, c.get("user").id, "update", "fee_category", id, {
        before: { name: before.name, active: before.active === 1 },
        after: { name: body.name ?? before.name, active: body.active ?? before.active === 1 },
      }),
    ]);
    return c.json(toCategory(await findCategory(db, id)), 200);
  })
  .openapi(setRateRoute, async (c) => {
    const { year, categoryId } = c.req.valid("param");
    const { amountCents, applyToUnpaid } = c.req.valid("json");
    const db = c.env.DB;
    await findCategory(db, categoryId);
    const previous = await db
      .prepare("SELECT amount_cents, updated_at FROM fee_rates WHERE category_id = ?1 AND year = ?2")
      .bind(categoryId, year)
      .first<{ amount_cents: number; updated_at: string }>();
    await assertNotModified(c, previous?.updated_at ?? null, { entity: "fee_rate", entityId: categoryId });
    const now = nowIso();
    const statements: D1PreparedStatement[] = [
      db
        .prepare(
          `INSERT INTO fee_rates (category_id, year, amount_cents, updated_at) VALUES (?1, ?2, ?3, ?4)
           ON CONFLICT (category_id, year) DO UPDATE SET amount_cents = excluded.amount_cents, updated_at = excluded.updated_at`,
        )
        .bind(categoryId, year, amountCents, now),
    ];
    if (applyToUnpaid) {
      // Solo quote senza pagamenti, non annullate e senza riduzioni personali.
      statements.push(
        db
          .prepare(
            `UPDATE dues SET base_amount_cents = ?1, amount_cents = ?1
              WHERE category_id = ?2 AND year = ?3 AND cancelled_at IS NULL
                AND amount_cents = base_amount_cents
                AND NOT EXISTS (
                  SELECT 1 FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
                   WHERE a.due_id = dues.id AND p.voided_at IS NULL)`,
          )
          .bind(amountCents, categoryId, year),
      );
    }
    statements.push(
      auditStatement(db, c.get("user").id, "update", "fee_rate", categoryId, {
        year,
        before: previous?.amount_cents ?? null,
        after: amountCents,
        applyToUnpaid,
      }),
    );
    const results = await db.batch(statements);
    const updatedDues = applyToUnpaid ? (results[1]?.meta.changes ?? 0) : 0;
    return c.json({ fee: await feeOf(db, categoryId, year), updatedDues }, 200);
  });
