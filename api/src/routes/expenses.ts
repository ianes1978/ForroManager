import { createRoute, z } from "@hono/zod-openapi";
import { assertDeletable } from "../data/usage.ts";
import { auditStatement } from "../lib/audit.ts";
import { assertNotModified } from "../lib/concurrency.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, IdempotencyHeaders, IfMatchHeaders, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { nowIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { idempotent } from "../middleware/idempotency.ts";

/**
 * Spese dell'associazione. Una spesa è pagata dalla cassa (con un metodo) oppure
 * anticipata da qualcuno (solo il nome) e poi rimborsata. has_receipt indica se
 * abbiamo la ricevuta. Le spese non sono riferite da altri dati: si correggono e si
 * eliminano liberamente (resta traccia nel registro delle modifiche).
 */

const ExpenseSchema = z
  .object({
    id: z.number().int(),
    spentOn: z.string(),
    description: z.string(),
    amountCents: z.number().int(),
    category: z.object({ id: z.number().int(), name: z.string() }),
    method: z.object({ code: z.string(), label: z.string() }).nullable().openapi({ description: "Come è stata pagata dalla cassa, o come è stato fatto il rimborso" }),
    advancedBy: z.string().nullable().openapi({ description: "Chi l'ha anticipata, se da rimborsare" }),
    reimbursedOn: z.string().nullable(),
    toReimburse: z.boolean(),
    hasReceipt: z.boolean(),
    note: z.string().nullable(),
    createdBy: z.string(),
    createdAt: z.string(),
    updatedAt: z.string(),
  })
  .openapi("Expense");

const CategorySchema = z.object({ id: z.number().int(), name: z.string(), active: z.boolean() }).openapi("ExpenseCategory");

const Fields = {
  spentOn: DateSchema,
  description: z.string().trim().min(1, "Descrivi la spesa.").max(120),
  amountCents: z.number().int("L'importo va indicato in centesimi.").positive("L'importo deve essere maggiore di zero.").max(10_000_000),
  categoryId: z.number().int().positive(),
  method: z.string().max(30).nullable(),
  advancedBy: z.string().trim().max(60).nullable(),
  reimbursedOn: DateSchema.nullable(),
  hasReceipt: z.boolean(),
  note: z.string().trim().max(500).nullable(),
};
const CreateSchema = z.object({
  ...Fields,
  method: Fields.method.optional(),
  advancedBy: Fields.advancedBy.optional(),
  reimbursedOn: Fields.reimbursedOn.optional(),
  hasReceipt: Fields.hasReceipt.default(false),
  note: Fields.note.optional(),
});
const UpdateSchema = z
  .object({
    spentOn: Fields.spentOn.optional(),
    description: Fields.description.optional(),
    amountCents: Fields.amountCents.optional(),
    categoryId: Fields.categoryId.optional(),
    method: Fields.method.optional(),
    advancedBy: Fields.advancedBy.optional(),
    reimbursedOn: Fields.reimbursedOn.optional(),
    hasReceipt: Fields.hasReceipt.optional(),
    note: Fields.note.optional(),
  })
  .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata.");

interface ExpenseRow {
  id: number;
  spent_on: string;
  description: string;
  amount_cents: number;
  category_id: number;
  category_name: string;
  method_id: number | null;
  method_code: string | null;
  method_label: string | null;
  advanced_by: string | null;
  reimbursed_on: string | null;
  has_receipt: number;
  note: string | null;
  created_by_name: string;
  created_at: string;
  updated_at: string;
}

const SELECT = `
  SELECT e.id, e.spent_on, e.description, e.amount_cents, e.category_id, c.name AS category_name,
         e.method_id, pm.code AS method_code, pm.label AS method_label, e.advanced_by, e.reimbursed_on, e.has_receipt, e.note,
         u.name AS created_by_name, e.created_at, e.updated_at
    FROM expenses e JOIN expense_categories c ON c.id = e.category_id
    LEFT JOIN payment_methods pm ON pm.id = e.method_id JOIN users u ON u.id = e.created_by`;

const toExpense = (r: ExpenseRow): z.infer<typeof ExpenseSchema> => ({
  id: r.id,
  spentOn: r.spent_on,
  description: r.description,
  amountCents: r.amount_cents,
  category: { id: r.category_id, name: r.category_name },
  method: r.method_code ? { code: r.method_code, label: r.method_label! } : null,
  advancedBy: r.advanced_by,
  reimbursedOn: r.reimbursed_on,
  toReimburse: r.advanced_by !== null && r.reimbursed_on === null,
  hasReceipt: r.has_receipt === 1,
  note: r.note,
  createdBy: r.created_by_name,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

async function findExpense(db: D1Database, id: number) {
  const row = await db.prepare(`${SELECT} WHERE e.id = ?1`).bind(id).first<ExpenseRow>();
  if (!row) throw notFound("Spesa non trovata.");
  return row;
}

async function methodId(db: D1Database, code: string | null | undefined, current?: string | null): Promise<number | null> {
  if (!code) return null;
  const m = await db.prepare("SELECT id FROM payment_methods WHERE code = ?1 AND (active = 1 OR code = ?2)").bind(code, current ?? null).first<{ id: number }>();
  if (!m) throw invalid("Metodo di pagamento non valido.", [{ field: "method", message: "Scegli un metodo attivo." }]);
  return m.id;
}

async function checkCategory(db: D1Database, id: number, current?: number) {
  const c = await db.prepare("SELECT id FROM expense_categories WHERE id = ?1 AND (active = 1 OR id = ?2)").bind(id, current ?? null).first();
  if (!c) throw invalid("Categoria non valida.", [{ field: "categoryId", message: "Scegli una categoria attiva." }]);
}

// --- Rotte -------------------------------------------------------------------
const listRoute = createRoute({
  method: "get", path: "/expenses", tags: ["Spese"], security: bearer, summary: "Spese per periodo, categoria, da rimborsare o senza ricevuta",
  request: {
    query: z.object({
      from: DateSchema.optional(),
      to: DateSchema.optional(),
      categoryId: z.coerce.number().int().positive().optional(),
      toReimburse: z.enum(["true", "false"]).optional().openapi({ description: "Solo quelle anticipate e non ancora rimborsate" }),
      noReceipt: z.enum(["true", "false"]).optional().openapi({ description: "Solo quelle senza ricevuta" }),
    }),
  },
  responses: {
    200: {
      description: "Spese",
      ...json(z.object({
        items: z.array(ExpenseSchema),
        totalCents: z.number().int().openapi({ description: "Totale delle spese elencate" }),
        toReimburseCents: z.number().int().openapi({ description: "Totale ancora da rimborsare (tutte le date)" }),
        toReimburseCount: z.number().int(),
      })),
    },
    ...commonErrors,
  },
});

const createExpenseRoute = createRoute({
  method: "post", path: "/expenses", tags: ["Spese"], security: bearer, summary: "Registra una spesa",
  middleware: [idempotent] as const,
  request: { headers: IdempotencyHeaders, body: json(CreateSchema) },
  responses: { 201: { description: "Spesa registrata", ...json(ExpenseSchema) }, ...commonErrors, 409: errors[409] },
});

const updateExpenseRoute = createRoute({
  method: "patch", path: "/expenses/{id}", tags: ["Spese"], security: bearer,
  summary: "Corregge una spesa, segna il rimborso o la ricevuta",
  request: { headers: IfMatchHeaders, params: IdParam, body: json(UpdateSchema) },
  responses: { 200: { description: "Spesa aggiornata", ...json(ExpenseSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const deleteExpenseRoute = createRoute({
  method: "delete", path: "/expenses/{id}", tags: ["Spese"], security: bearer, summary: "Elimina una spesa registrata per errore",
  request: { params: IdParam },
  responses: { 204: { description: "Spesa eliminata" }, ...commonErrors, 404: errors[404] },
});

const categoriesRoute = createRoute({
  method: "get", path: "/expense-categories", tags: ["Spese"], security: bearer, summary: "Categorie delle spese",
  responses: { 200: { description: "Categorie", ...json(z.object({ items: z.array(CategorySchema) })) }, ...commonErrors },
});

const createCategoryRoute = createRoute({
  method: "post", path: "/expense-categories", tags: ["Spese"], security: bearer, summary: "Nuova categoria di spesa",
  request: { body: json(z.object({ name: z.string().trim().min(1, "Il nome è obbligatorio.").max(40) })) },
  responses: { 201: { description: "Categoria creata", ...json(CategorySchema) }, ...commonErrors, 409: errors[409] },
});

const updateCategoryRoute = createRoute({
  method: "patch", path: "/expense-categories/{id}", tags: ["Spese"], security: bearer, summary: "Rinomina o disattiva una categoria di spesa",
  request: {
    params: IdParam,
    body: json(z.object({ name: z.string().trim().min(1).max(40).optional(), active: z.boolean().optional() }).refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata.")),
  },
  responses: { 200: { description: "Categoria aggiornata", ...json(CategorySchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const deleteCategoryRoute = createRoute({
  method: "delete", path: "/expense-categories/{id}", tags: ["Spese"], security: bearer, summary: "Elimina una categoria senza spese",
  request: { params: IdParam },
  responses: { 204: { description: "Categoria eliminata" }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

export const expenseRoutes = createRouter();
for (const path of ["/expenses", "/expenses/*", "/expense-categories", "/expense-categories/*"]) expenseRoutes.use(path, requireAuth);

expenseRoutes
  .openapi(listRoute, async (c) => {
    const q = c.req.valid("query");
    const where: string[] = [];
    const params: unknown[] = [];
    const add = (sql: string, value?: unknown) => {
      if (value !== undefined) {
        params.push(value);
        sql = sql.replace("?", `?${params.length}`);
      }
      where.push(sql);
    };
    if (q.from) add("e.spent_on >= ?", q.from);
    if (q.to) add("e.spent_on <= ?", q.to);
    if (q.categoryId) add("e.category_id = ?", q.categoryId);
    if (q.toReimburse === "true") add("e.advanced_by IS NOT NULL AND e.reimbursed_on IS NULL");
    if (q.noReceipt === "true") add("e.has_receipt = 0");
    const filter = where.length ? `WHERE ${where.join(" AND ")}` : "";
    const db = c.env.DB;
    const [rows, open] = await db.batch([
      db.prepare(`${SELECT} ${filter} ORDER BY e.spent_on DESC, e.id DESC LIMIT 500`).bind(...params),
      db.prepare("SELECT COALESCE(SUM(amount_cents), 0) AS cents, COUNT(*) AS n FROM expenses WHERE advanced_by IS NOT NULL AND reimbursed_on IS NULL"),
    ]);
    const items = (rows!.results as unknown as ExpenseRow[]).map(toExpense);
    const o = (open!.results as { cents: number; n: number }[])[0]!;
    return c.json({ items, totalCents: items.reduce((s, e) => s + e.amountCents, 0), toReimburseCents: o.cents, toReimburseCount: o.n }, 200);
  })
  .openapi(createExpenseRoute, async (c) => {
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    await checkCategory(db, b.categoryId);
    const method = await methodId(db, b.method);
    const advancedBy = b.advancedBy || null;
    if (b.reimbursedOn && !advancedBy) throw invalid("Il rimborso vale solo per una spesa anticipata da qualcuno.", [{ field: "reimbursedOn", message: "Indica chi l'ha anticipata." }]);
    const now = nowIso();
    const row = await db
      .prepare(
        `INSERT INTO expenses (spent_on, description, amount_cents, category_id, method_id, advanced_by, reimbursed_on, has_receipt, note, created_at, created_by, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?10) RETURNING id`,
      )
      .bind(b.spentOn, b.description, b.amountCents, b.categoryId, method, advancedBy, b.reimbursedOn ?? null, Number(b.hasReceipt), b.note || null, now, me)
      .first<{ id: number }>();
    await auditStatement(db, me, "create", "expense", row!.id, { description: b.description, amountCents: b.amountCents, spentOn: b.spentOn }).run();
    return c.json(toExpense(await findExpense(db, row!.id)), 201);
  })
  .openapi(updateExpenseRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const before = await findExpense(db, id);
    await assertNotModified(c, before.updated_at, { entity: "expense", entityId: id });
    if (b.categoryId !== undefined) await checkCategory(db, b.categoryId, before.category_id);
    const method = b.method === undefined ? undefined : await methodId(db, b.method, before.method_code);
    const advancedBy = b.advancedBy === undefined ? before.advanced_by : b.advancedBy || null;
    // Se non è più anticipata da nessuno, il rimborso non ha senso e si toglie.
    const reimbursedOn = advancedBy === null ? null : b.reimbursedOn === undefined ? before.reimbursed_on : b.reimbursedOn;
    if (b.reimbursedOn && !advancedBy) throw invalid("Il rimborso vale solo per una spesa anticipata da qualcuno.", [{ field: "reimbursedOn", message: "Indica chi l'ha anticipata." }]);
    // Versione al millisecondo: due correzioni ravvicinate restano distinguibili.
    const version = new Date().toISOString();
    await db.batch([
      db
        .prepare(
          `UPDATE expenses SET spent_on = ?1, description = ?2, amount_cents = ?3, category_id = ?4, method_id = ?5, advanced_by = ?6,
                  reimbursed_on = ?7, has_receipt = ?8, note = ?9, updated_at = ?10 WHERE id = ?11`,
        )
        .bind(
          b.spentOn ?? before.spent_on,
          b.description ?? before.description,
          b.amountCents ?? before.amount_cents,
          b.categoryId ?? before.category_id,
          method === undefined ? before.method_id : method,
          advancedBy,
          reimbursedOn,
          b.hasReceipt === undefined ? before.has_receipt : Number(b.hasReceipt),
          b.note === undefined ? before.note : b.note || null,
          version,
          id,
        ),
      auditStatement(db, c.get("user").id, "update", "expense", id, {
        before: { description: before.description, amountCents: before.amount_cents, spentOn: before.spent_on, reimbursedOn: before.reimbursed_on, hasReceipt: before.has_receipt === 1 },
        changes: b,
      }),
    ]);
    return c.json(toExpense(await findExpense(db, id)), 200);
  })
  .openapi(deleteExpenseRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const e = await findExpense(db, id);
    await db.batch([
      db.prepare("DELETE FROM expenses WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "expense", id, { description: e.description, amountCents: e.amount_cents, spentOn: e.spent_on }),
    ]);
    return c.body(null, 204);
  })
  .openapi(categoriesRoute, async (c) => {
    const { results } = await c.env.DB.prepare("SELECT id, name, active FROM expense_categories ORDER BY active DESC, sort_order, name").all<{ id: number; name: string; active: number }>();
    return c.json({ items: results.map((r) => ({ id: r.id, name: r.name, active: r.active === 1 })) }, 200);
  })
  .openapi(createCategoryRoute, async (c) => {
    const { name } = c.req.valid("json");
    const db = c.env.DB;
    if (await db.prepare("SELECT 1 FROM expense_categories WHERE name = ?1").bind(name).first()) throw conflict("category_exists", "Esiste già una categoria con questo nome.");
    const row = await db
      .prepare("INSERT INTO expense_categories (name, sort_order, created_at) VALUES (?1, (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM expense_categories), ?2) RETURNING id")
      .bind(name, nowIso())
      .first<{ id: number }>();
    await auditStatement(db, c.get("user").id, "create", "expense_category", row!.id, { name }).run();
    return c.json({ id: row!.id, name, active: true }, 201);
  })
  .openapi(updateCategoryRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    if (b.name && (await db.prepare("SELECT 1 FROM expense_categories WHERE name = ?1 AND id <> ?2").bind(b.name, id).first())) {
      throw conflict("category_exists", "Esiste già una categoria con questo nome.");
    }
    const res = await db
      .prepare("UPDATE expense_categories SET name = COALESCE(?1, name), active = COALESCE(?2, active) WHERE id = ?3")
      .bind(b.name ?? null, b.active === undefined ? null : Number(b.active), id)
      .run();
    if (!res.meta.changes) throw notFound("Categoria non trovata.");
    await auditStatement(db, c.get("user").id, "update", "expense_category", id, b).run();
    const r = await db.prepare("SELECT id, name, active FROM expense_categories WHERE id = ?1").bind(id).first<{ id: number; name: string; active: number }>();
    return c.json({ id: r!.id, name: r!.name, active: r!.active === 1 }, 200);
  })
  .openapi(deleteCategoryRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "expense-category", id, "category_in_use");
    await db.batch([
      db.prepare("DELETE FROM expense_categories WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "expense_category", id, { name: usage.name }),
    ]);
    return c.body(null, 204);
  });

