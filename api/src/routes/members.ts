import { createRoute, z } from "@hono/zod-openapi";
import { formatYearMonth, overlaps, parseYearMonth } from "../domain/periods.ts";
import { auditStatement } from "../lib/audit.ts";
import { assertNotModified } from "../lib/concurrency.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, YearMonthSchema, bearer, commonErrors, createRouter, errors, IfMatchHeaders, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { SUMMARY_CTE, type SummaryColumns, summaryParams, toSummary } from "../data/summary.ts";
import {
  MEMBER_SELECT,
  MemberDetailSchema,
  MemberInputSchema,
  MemberListItemSchema,
  type MemberRow,
  MemberSchema,
  SuspensionSchema,
  toMember,
} from "../schemas/members.ts";

const listRoute = createRoute({
  method: "get",
  path: "/members",
  tags: ["Soci"],
  summary: "Elenco dei soci con ricerca per nome o cognome",
  security: bearer,
  request: {
    query: z.object({
      q: z.string().trim().max(80).optional(),
      status: z.enum(["attivo", "cessato", "tutti"]).default("attivo"),
      filter: z.enum(["arretrati", "moduli"]).optional().openapi({ description: "Solo soci con arretrati o con moduli da riavere" }),
    }),
  },
  responses: {
    200: { description: "Soci con riepilogo di arretrati, prodotti da saldare e moduli mancanti", ...json(z.object({ items: z.array(MemberListItemSchema) })) },
    ...commonErrors,
  },
});

const getRoute = createRoute({
  method: "get",
  path: "/members/{id}",
  tags: ["Soci"],
  summary: "Scheda del socio",
  security: bearer,
  request: { params: IdParam },
  responses: { 200: { description: "Socio", ...json(MemberDetailSchema) }, ...commonErrors, 404: errors[404] },
});

const createMemberRoute = createRoute({
  method: "post",
  path: "/members",
  tags: ["Soci"],
  summary: "Nuovo socio",
  security: bearer,
  request: { body: json(MemberInputSchema) },
  responses: { 201: { description: "Socio creato", ...json(MemberDetailSchema) }, ...commonErrors },
});

const updateRoute = createRoute({
  method: "patch",
  path: "/members/{id}",
  tags: ["Soci"],
  summary: "Modifica i dati del socio",
  security: bearer,
  request: {
    headers: IfMatchHeaders,
    params: IdParam,
    body: json(MemberInputSchema.partial().refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata.")),
  },
  responses: { 200: { description: "Socio aggiornato", ...json(MemberDetailSchema) }, ...commonErrors, 404: errors[404] },
});

const ceaseRoute = createRoute({
  method: "post",
  path: "/members/{id}/cease",
  tags: ["Soci"],
  summary: "Segna il socio come cessato (non riceverà nuove quote)",
  security: bearer,
  request: { params: IdParam, body: json(z.object({ ceasedOn: DateSchema.optional() })) },
  responses: {
    200: { description: "Socio cessato", ...json(MemberDetailSchema) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

const reactivateRoute = createRoute({
  method: "post",
  path: "/members/{id}/reactivate",
  tags: ["Soci"],
  summary: "Riattiva un socio cessato",
  security: bearer,
  request: { params: IdParam },
  responses: {
    200: { description: "Socio riattivato", ...json(MemberDetailSchema) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

const addSuspensionRoute = createRoute({
  method: "post",
  path: "/members/{id}/suspensions",
  tags: ["Soci"],
  summary: "Sospende il socio per alcuni mesi (niente quote mensili in quel periodo)",
  security: bearer,
  request: {
    params: IdParam,
    body: json(
      z.object({
        from: YearMonthSchema,
        to: YearMonthSchema,
        reason: z.string().trim().max(200).optional(),
      }),
    ),
  },
  responses: {
    201: { description: "Sospensione registrata", ...json(SuspensionSchema) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

const cancelSuspensionRoute = createRoute({
  method: "post",
  path: "/members/{id}/suspensions/{suspensionId}/cancel",
  tags: ["Soci"],
  summary: "Annulla una sospensione",
  security: bearer,
  request: {
    params: IdParam.extend({
      suspensionId: z.coerce.number().int().positive().openapi({ param: { name: "suspensionId", in: "path" } }),
    }),
  },
  responses: { 204: { description: "Sospensione annullata" }, ...commonErrors, 404: errors[404] },
});

interface SuspensionRow {
  id: number;
  from_period: number;
  to_period: number;
  reason: string | null;
  created_at: string;
}

async function findMemberRow(db: D1Database, id: number): Promise<MemberRow> {
  const row = await db.prepare(`${MEMBER_SELECT} WHERE m.id = ?1`).bind(id).first<MemberRow>();
  if (!row) throw notFound("Socio non trovato.");
  return row;
}

async function activeSuspensions(db: D1Database, memberId: number): Promise<SuspensionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT id, from_period, to_period, reason, created_at FROM member_suspensions
        WHERE member_id = ?1 AND cancelled_at IS NULL ORDER BY from_period`,
    )
    .bind(memberId)
    .all<SuspensionRow>();
  return results;
}

const toSuspension = (s: SuspensionRow) => ({
  id: s.id,
  from: formatYearMonth(s.from_period),
  to: formatYearMonth(s.to_period),
  reason: s.reason,
  createdAt: s.created_at,
});

async function memberDetail(db: D1Database, id: number) {
  const [row, suspensions] = await Promise.all([findMemberRow(db, id), activeSuspensions(db, id)]);
  return { ...toMember(row), suspensions: suspensions.map(toSuspension) };
}

/** Verifica che la categoria esista, sia attiva e del tipo giusto; se assente usa la prima attiva. */
async function resolveCategory(db: D1Database, kind: "annuale" | "mensile", id: number | undefined): Promise<number> {
  const row = id
    ? await db.prepare("SELECT id FROM fee_categories WHERE id = ?1 AND kind = ?2 AND active = 1").bind(id, kind).first<{ id: number }>()
    : await db.prepare("SELECT id FROM fee_categories WHERE kind = ?1 AND active = 1 ORDER BY id LIMIT 1").bind(kind).first<{ id: number }>();
  if (!row) {
    const field = kind === "annuale" ? "annualCategoryId" : "monthlyCategoryId";
    throw invalid("Tariffa non valida.", [{ field, message: `Scegli una tariffa ${kind} attiva.` }]);
  }
  return row.id;
}

/** Escape dei caratteri speciali di LIKE. */
const likePattern = (q: string) => `%${q.replace(/[\\%_]/g, (ch) => `\\${ch}`)}%`;

const FIELD_COLUMNS = {
  firstName: "first_name",
  lastName: "last_name",
  email: "email",
  phone: "phone",
  joinedOn: "joined_on",
  notes: "notes",
  annualCategoryId: "annual_category_id",
  monthlyCategoryId: "monthly_category_id",
} as const;

export const memberRoutes = createRouter();
memberRoutes.use("/members", requireAuth);
memberRoutes.use("/members/*", requireAuth);

memberRoutes
  .openapi(listRoute, async (c) => {
    const { q, status, filter } = c.req.valid("query");
    const params: unknown[] = [...summaryParams(todayIso())];
    const where: string[] = [];
    if (status !== "tutti") {
      params.push(status);
      where.push(`m.status = ?${params.length}`);
    }
    if (q) {
      for (const word of q.split(/\s+/).filter(Boolean)) {
        params.push(likePattern(word));
        where.push(`(m.first_name LIKE ?${params.length} ESCAPE '\\' OR m.last_name LIKE ?${params.length} ESCAPE '\\')`);
      }
    }
    if (filter === "arretrati") where.push("COALESCE(s.arrears_cents, 0) > 0");
    if (filter === "moduli") where.push("COALESCE(f.missing_forms, 0) > 0");
    const sql = `WITH ${SUMMARY_CTE}
                 ${MEMBER_SELECT.replace("FROM members m", "FROM members m LEFT JOIN member_summary s ON s.member_id = m.id LEFT JOIN member_forms_missing f ON f.member_id = m.id").replace("m.created_at, m.updated_at", "m.created_at, m.updated_at, s.arrears_cents, s.arrears_count, s.open_charges_cents, s.open_charges_count, f.missing_forms")}
                 ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
                 ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`;
    const { results } = await c.env.DB.prepare(sql).bind(...params).all<MemberRow & SummaryColumns>();
    return c.json({ items: results.map((r) => ({ ...toMember(r), summary: toSummary(r) })) }, 200);
  })
  .openapi(getRoute, async (c) => c.json(await memberDetail(c.env.DB, c.req.valid("param").id), 200))
  .openapi(createMemberRoute, async (c) => {
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const annual = await resolveCategory(db, "annuale", body.annualCategoryId);
    const monthly = await resolveCategory(db, "mensile", body.monthlyCategoryId);
    const now = nowIso();
    const row = await db
      .prepare(
        `INSERT INTO members (first_name, last_name, email, phone, joined_on, notes, annual_category_id, monthly_category_id,
                              created_at, created_by, updated_at, updated_by)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?9, ?10) RETURNING id`,
      )
      .bind(body.firstName, body.lastName, body.email ?? null, body.phone ?? null, body.joinedOn, body.notes ?? null, annual, monthly, now, me)
      .first<{ id: number }>();
    await auditStatement(db, me, "create", "member", row!.id).run();
    return c.json(await memberDetail(db, row!.id), 201);
  })
  .openapi(updateRoute, async (c) => {
    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const before = await findMemberRow(db, id);
    await assertNotModified(c, before.updated_at, { entity: "member", entityId: id });
    if (body.annualCategoryId !== undefined) await resolveCategory(db, "annuale", body.annualCategoryId);
    if (body.monthlyCategoryId !== undefined) await resolveCategory(db, "mensile", body.monthlyCategoryId);

    const sets: string[] = [];
    const params: unknown[] = [];
    const changes: Record<string, { before: unknown; after: unknown }> = {};
    for (const [field, column] of Object.entries(FIELD_COLUMNS) as [keyof typeof FIELD_COLUMNS, string][]) {
      const value = body[field];
      if (value === undefined) continue;
      const old = (before as unknown as Record<string, unknown>)[column];
      if (value === old) continue;
      params.push(value);
      sets.push(`${column} = ?${params.length}`);
      changes[field] = { before: old, after: value };
    }
    if (sets.length) {
      params.push(nowIso(), me, id);
      await db.batch([
        db
          .prepare(`UPDATE members SET ${sets.join(", ")}, updated_at = ?${params.length - 2}, updated_by = ?${params.length - 1} WHERE id = ?${params.length}`)
          .bind(...params),
        auditStatement(db, me, "update", "member", id, changes),
      ]);
    }
    return c.json(await memberDetail(db, id), 200);
  })
  .openapi(ceaseRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { ceasedOn } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const before = await findMemberRow(db, id);
    if (before.status === "cessato") throw conflict("already_ceased", "Il socio è già cessato.");
    const date = ceasedOn ?? todayIso();
    if (date < before.joined_on) throw invalid("La cessazione non può precedere l'iscrizione.", [{ field: "ceasedOn", message: "Data precedente all'iscrizione." }]);
    const now = nowIso();
    await db.batch([
      db
        .prepare("UPDATE members SET status = 'cessato', ceased_on = ?1, updated_at = ?2, updated_by = ?3 WHERE id = ?4")
        .bind(date, now, me, id),
      auditStatement(db, me, "cease", "member", id, { ceasedOn: date }),
    ]);
    return c.json(await memberDetail(db, id), 200);
  })
  .openapi(reactivateRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const me = c.get("user").id;
    const before = await findMemberRow(db, id);
    if (before.status === "attivo") throw conflict("already_active", "Il socio è già attivo.");
    await db.batch([
      db
        .prepare("UPDATE members SET status = 'attivo', ceased_on = NULL, updated_at = ?1, updated_by = ?2 WHERE id = ?3")
        .bind(nowIso(), me, id),
      auditStatement(db, me, "update", "member", id, { status: { before: "cessato", after: "attivo" }, ceasedOn: before.ceased_on }),
    ]);
    return c.json(await memberDetail(db, id), 200);
  })
  .openapi(addSuspensionRoute, async (c) => {
    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    await findMemberRow(db, id);
    const interval = { from: parseYearMonth(body.from), to: parseYearMonth(body.to) };
    if (interval.to < interval.from) {
      throw invalid("Il mese finale precede quello iniziale.", [{ field: "to", message: "Deve essere uguale o successivo al mese iniziale." }]);
    }
    const existing = await activeSuspensions(db, id);
    if (existing.some((s) => overlaps(interval, { from: s.from_period, to: s.to_period }))) {
      throw conflict("suspension_overlap", "Il periodo si sovrappone a una sospensione già registrata.");
    }
    const row = await db
      .prepare(
        `INSERT INTO member_suspensions (member_id, from_period, to_period, reason, created_at, created_by)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6) RETURNING id, from_period, to_period, reason, created_at`,
      )
      .bind(id, interval.from, interval.to, body.reason || null, nowIso(), me)
      .first<SuspensionRow>();
    await auditStatement(db, me, "create", "suspension", row!.id, { memberId: id, from: body.from, to: body.to }).run();
    return c.json(toSuspension(row!), 201);
  })
  .openapi(cancelSuspensionRoute, async (c) => {
    const { id, suspensionId } = c.req.valid("param");
    const db = c.env.DB;
    const me = c.get("user").id;
    const result = await db
      .prepare(
        "UPDATE member_suspensions SET cancelled_at = ?1, cancelled_by = ?2 WHERE id = ?3 AND member_id = ?4 AND cancelled_at IS NULL",
      )
      .bind(nowIso(), me, suspensionId, id)
      .run();
    if (!result.meta.changes) throw notFound("Sospensione non trovata.");
    await auditStatement(db, me, "cancel", "suspension", suspensionId, { memberId: id }).run();
    return c.body(null, 204);
  });
