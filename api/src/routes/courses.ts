import { createRoute, z } from "@hono/zod-openapi";
import { defaultPeriodName } from "../domain/dues.ts";
import { formatYearMonth, monthOf, parseYearMonth, yearOf } from "../domain/periods.ts";
import { auditStatement } from "../lib/audit.ts";
import { assertNotModified } from "../lib/concurrency.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { IdParam, IfMatchHeaders, YearMonthSchema, YearSchema, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

/**
 * Corsi (es. Forró, Zouk) con periodi di durata libera e prezzo proprio.
 * Iscrivere un socio a un periodo crea la sua quota per quel periodo.
 */

const PeriodSchema = z
  .object({
    id: z.number().int(),
    courseId: z.number().int(),
    courseName: z.string(),
    name: z.string().openapi({ example: "gen–mar 2026" }),
    label: z.string().openapi({ example: "Forró gen–mar 2026" }),
    from: YearMonthSchema,
    to: YearMonthSchema,
    months: z.number().int(),
    amountCents: z.number().int(),
    active: z.boolean(),
    enrolled: z.number().int().openapi({ description: "Soci iscritti" }),
    paid: z.number().int().openapi({ description: "Iscritti che hanno pagato per intero" }),
    updatedAt: z.string(),
  })
  .openapi("CoursePeriod");

const CourseSchema = z
  .object({ id: z.number().int(), name: z.string(), active: z.boolean(), periods: z.array(PeriodSchema), updatedAt: z.string() })
  .openapi("Course");

const EnrollmentSchema = z
  .object({
    dueId: z.number().int(),
    memberId: z.number().int(),
    memberName: z.string(),
    amountCents: z.number().int(),
    paidCents: z.number().int(),
    adjustmentReason: z.string().nullable(),
  })
  .openapi("Enrollment");

interface PeriodRow {
  id: number;
  course_id: number;
  course_name: string;
  name: string;
  from_period: number;
  to_period: number;
  amount_cents: number;
  active: number;
  enrolled: number;
  paid: number;
  updated_at: string;
}

const PAID = `COALESCE((SELECT SUM(a.amount_cents) FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
                         WHERE a.due_id = d.id AND p.voided_at IS NULL), 0)`;

const PERIOD_SELECT = `
  SELECT cp.id, cp.course_id, co.name AS course_name, cp.name, cp.from_period, cp.to_period, cp.amount_cents, cp.active, cp.updated_at,
         (SELECT COUNT(*) FROM dues d WHERE d.course_period_id = cp.id AND d.kind = 'periodo' AND d.cancelled_at IS NULL) AS enrolled,
         (SELECT COUNT(*) FROM dues d WHERE d.course_period_id = cp.id AND d.kind = 'periodo' AND d.cancelled_at IS NULL
                                        AND ${PAID} >= d.amount_cents) AS paid
    FROM course_periods cp JOIN courses co ON co.id = cp.course_id`;

const toPeriod = (r: PeriodRow) => ({
  id: r.id,
  courseId: r.course_id,
  courseName: r.course_name,
  name: r.name,
  label: `${r.course_name} ${r.name}`,
  from: formatYearMonth(r.from_period),
  to: formatYearMonth(r.to_period),
  months: r.to_period - r.from_period + 1,
  amountCents: r.amount_cents,
  active: r.active === 1,
  enrolled: r.enrolled,
  paid: r.paid,
  updatedAt: r.updated_at,
});

async function findPeriod(db: D1Database, id: number): Promise<PeriodRow> {
  const row = await db.prepare(`${PERIOD_SELECT} WHERE cp.id = ?1`).bind(id).first<PeriodRow>();
  if (!row) throw notFound("Periodo non trovato.");
  return row;
}

async function findCourse(db: D1Database, id: number) {
  const row = await db.prepare("SELECT id, name, active, updated_at FROM courses WHERE id = ?1").bind(id).first<{ id: number; name: string; active: number; updated_at: string }>();
  if (!row) throw notFound("Corso non trovato.");
  return row;
}

const PeriodIdParam = z.object({ periodId: z.coerce.number().int().positive().openapi({ param: { name: "periodId", in: "path" } }) });

// --- Rotte -------------------------------------------------------------------
const listRoute = createRoute({
  method: "get", path: "/courses", tags: ["Corsi"], security: bearer,
  summary: "Corsi con i loro periodi (dell'anno indicato o tutti)",
  request: { query: z.object({ year: YearSchema.optional().openapi({ description: "Solo i periodi che toccano quest'anno" }) }) },
  responses: { 200: { description: "Corsi", ...json(z.object({ items: z.array(CourseSchema) })) }, ...commonErrors },
});

const createCourseRoute = createRoute({
  method: "post", path: "/courses", tags: ["Corsi"], security: bearer, summary: "Nuovo corso",
  request: { body: json(z.object({ name: z.string().trim().min(1, "Il nome è obbligatorio.").max(60) })) },
  responses: { 201: { description: "Corso creato", ...json(CourseSchema) }, ...commonErrors, 409: errors[409] },
});

const updateCourseRoute = createRoute({
  method: "patch", path: "/courses/{id}", tags: ["Corsi"], security: bearer, summary: "Rinomina o disattiva un corso",
  request: {
    params: IdParam,
    body: json(z.object({ name: z.string().trim().min(1).max(60).optional(), active: z.boolean().optional() }).refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata.")),
  },
  responses: { 200: { description: "Corso aggiornato", ...json(CourseSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const createPeriodRoute = createRoute({
  method: "post", path: "/courses/{id}/periods", tags: ["Corsi"], security: bearer,
  summary: "Nuovo periodo del corso (un mese, un trimestre, un quadrimestre...) con il suo prezzo",
  request: {
    params: IdParam,
    body: json(
      z.object({
        from: YearMonthSchema,
        to: YearMonthSchema,
        amountCents: z.number().int("L'importo va indicato in centesimi.").min(0).max(10_000_000),
        name: z.string().trim().max(40).optional().openapi({ description: "Predefinito: es. \"gen–mar 2026\"" }),
      }),
    ),
  },
  responses: { 201: { description: "Periodo creato", ...json(PeriodSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const updatePeriodRoute = createRoute({
  method: "patch", path: "/course-periods/{periodId}", tags: ["Corsi"], security: bearer,
  summary: "Modifica nome, prezzo o stato di un periodo",
  description: "Con applyToUnpaid il nuovo prezzo vale anche per le iscrizioni senza pagamenti né riduzioni personali.",
  request: {
    headers: IfMatchHeaders,
    params: PeriodIdParam,
    body: json(
      z
        .object({
          name: z.string().trim().min(1).max(40).optional(),
          amountCents: z.number().int().min(0).max(10_000_000).optional(),
          active: z.boolean().optional(),
          applyToUnpaid: z.boolean().default(false),
        })
        .refine((v) => v.name !== undefined || v.amountCents !== undefined || v.active !== undefined, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Periodo aggiornato", ...json(z.object({ period: PeriodSchema, updatedDues: z.number().int() })) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const enrollmentsRoute = createRoute({
  method: "get", path: "/course-periods/{periodId}/enrollments", tags: ["Corsi"], security: bearer, summary: "Iscritti al periodo",
  request: { params: PeriodIdParam },
  responses: { 200: { description: "Iscritti", ...json(z.object({ period: PeriodSchema, items: z.array(EnrollmentSchema) })) }, ...commonErrors, 404: errors[404] },
});

const enrollRoute = createRoute({
  method: "post", path: "/course-periods/{periodId}/enroll", tags: ["Corsi"], security: bearer,
  summary: "Iscrive dei soci al periodo (crea le loro quote; chi è già iscritto viene saltato)",
  request: {
    params: PeriodIdParam,
    body: json(
      z.union([
        z.object({ memberIds: z.array(z.number().int().positive()).min(1).max(300) }),
        z.object({ renewFromPeriodId: z.number().int().positive().openapi({ description: "Iscrive i soci attivi iscritti a quest'altro periodo" }) }),
      ]),
    ),
  },
  responses: { 200: { description: "Esito", ...json(z.object({ enrolled: z.number().int(), alreadyEnrolled: z.number().int() })) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

export const courseRoutes = createRouter();
for (const path of ["/courses", "/courses/*", "/course-periods/*"]) courseRoutes.use(path, requireAuth);

courseRoutes
  .openapi(listRoute, async (c) => {
    const { year } = c.req.valid("query");
    const db = c.env.DB;
    const filter = year ? `WHERE cp.from_period <= ${(year + 1) * 12 - 1} AND cp.to_period >= ${year * 12}` : "";
    const [courses, periods] = await db.batch([
      db.prepare("SELECT id, name, active, updated_at FROM courses ORDER BY active DESC, name COLLATE NOCASE"),
      db.prepare(`${PERIOD_SELECT} ${filter} ORDER BY cp.from_period, cp.id`),
    ]);
    const ps = (periods!.results as unknown as PeriodRow[]).map(toPeriod);
    const items = (courses!.results as { id: number; name: string; active: number; updated_at: string }[]).map((co) => ({
      id: co.id,
      name: co.name,
      active: co.active === 1,
      updatedAt: co.updated_at,
      periods: ps.filter((p) => p.courseId === co.id),
    }));
    return c.json({ items }, 200);
  })
  .openapi(createCourseRoute, async (c) => {
    const { name } = c.req.valid("json");
    const db = c.env.DB;
    if (await db.prepare("SELECT 1 FROM courses WHERE name = ?1").bind(name).first()) throw conflict("course_exists", "Esiste già un corso con questo nome.");
    const now = nowIso();
    const row = await db.prepare("INSERT INTO courses (name, created_at, updated_at) VALUES (?1, ?2, ?2) RETURNING id").bind(name, now).first<{ id: number }>();
    await auditStatement(db, c.get("user").id, "create", "course", row!.id, { name }).run();
    return c.json({ id: row!.id, name, active: true, updatedAt: now, periods: [] }, 201);
  })
  .openapi(updateCourseRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const before = await findCourse(db, id);
    if (b.name && (await db.prepare("SELECT 1 FROM courses WHERE name = ?1 AND id <> ?2").bind(b.name, id).first())) {
      throw conflict("course_exists", "Esiste già un corso con questo nome.");
    }
    await db.batch([
      db.prepare("UPDATE courses SET name = COALESCE(?1, name), active = COALESCE(?2, active), updated_at = ?3 WHERE id = ?4")
        .bind(b.name ?? null, b.active === undefined ? null : Number(b.active), nowIso(), id),
      auditStatement(db, c.get("user").id, "update", "course", id, { before: { name: before.name, active: before.active === 1 }, changes: b }),
    ]);
    const co = await findCourse(db, id);
    const { results } = await db.prepare(`${PERIOD_SELECT} WHERE cp.course_id = ?1 ORDER BY cp.from_period`).bind(id).all<PeriodRow>();
    return c.json({ id: co.id, name: co.name, active: co.active === 1, updatedAt: co.updated_at, periods: results.map(toPeriod) }, 200);
  })
  .openapi(createPeriodRoute, async (c) => {
    const { id } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const course = await findCourse(db, id);
    const from = parseYearMonth(b.from);
    const to = parseYearMonth(b.to);
    if (to < from) throw invalid("Il mese finale precede quello iniziale.", [{ field: "to", message: "Deve essere uguale o successivo al mese iniziale." }]);
    if (to - from > 23) throw invalid("Un periodo può durare al massimo 24 mesi.", [{ field: "to", message: "Periodo troppo lungo." }]);
    if (await db.prepare("SELECT 1 FROM course_periods WHERE course_id = ?1 AND from_period = ?2 AND to_period = ?3").bind(id, from, to).first()) {
      throw conflict("period_exists", "Questo periodo esiste già per il corso.");
    }
    const name = b.name || defaultPeriodName(yearOf(from), monthOf(from), yearOf(to), monthOf(to));
    const now = nowIso();
    const row = await db
      .prepare("INSERT INTO course_periods (course_id, name, from_period, to_period, amount_cents, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6) RETURNING id")
      .bind(id, name, from, to, b.amountCents, now)
      .first<{ id: number }>();
    await auditStatement(db, c.get("user").id, "create", "course_period", row!.id, { course: course.name, name, from: b.from, to: b.to, amountCents: b.amountCents }).run();
    return c.json(toPeriod(await findPeriod(db, row!.id)), 201);
  })
  .openapi(updatePeriodRoute, async (c) => {
    const { periodId } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const before = await findPeriod(db, periodId);
    await assertNotModified(c, before.updated_at, { entity: "course_period", entityId: periodId });
    const statements: D1PreparedStatement[] = [
      db.prepare("UPDATE course_periods SET name = COALESCE(?1, name), amount_cents = COALESCE(?2, amount_cents), active = COALESCE(?3, active), updated_at = ?4 WHERE id = ?5")
        .bind(b.name ?? null, b.amountCents ?? null, b.active === undefined ? null : Number(b.active), nowIso(), periodId),
    ];
    const reprice = b.applyToUnpaid && b.amountCents !== undefined;
    if (reprice) {
      statements.push(
        db.prepare(
          `UPDATE dues SET base_amount_cents = ?1, amount_cents = ?1
            WHERE course_period_id = ?2 AND kind = 'periodo' AND cancelled_at IS NULL AND amount_cents = base_amount_cents
              AND NOT EXISTS (SELECT 1 FROM payment_allocations a JOIN payments p ON p.id = a.payment_id WHERE a.due_id = dues.id AND p.voided_at IS NULL)`,
        ).bind(b.amountCents, periodId),
      );
    }
    statements.push(
      auditStatement(db, c.get("user").id, "update", "course_period", periodId, {
        before: { name: before.name, amountCents: before.amount_cents, active: before.active === 1 },
        changes: b,
      }),
    );
    const results = await db.batch(statements);
    return c.json({ period: toPeriod(await findPeriod(db, periodId)), updatedDues: reprice ? (results[1]?.meta.changes ?? 0) : 0 }, 200);
  })
  .openapi(enrollmentsRoute, async (c) => {
    const { periodId } = c.req.valid("param");
    const db = c.env.DB;
    const period = await findPeriod(db, periodId);
    const { results } = await db
      .prepare(
        `SELECT d.id, m.id AS member_id, m.last_name, m.first_name, d.amount_cents, d.adjustment_reason, ${PAID} AS paid_cents
           FROM dues d JOIN members m ON m.id = d.member_id
          WHERE d.course_period_id = ?1 AND d.kind = 'periodo' AND d.cancelled_at IS NULL
          ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`,
      )
      .bind(periodId)
      .all<{ id: number; member_id: number; last_name: string; first_name: string; amount_cents: number; adjustment_reason: string | null; paid_cents: number }>();
    return c.json(
      {
        period: toPeriod(period),
        items: results.map((r) => ({
          dueId: r.id, memberId: r.member_id, memberName: `${r.last_name} ${r.first_name}`, amountCents: r.amount_cents, paidCents: r.paid_cents, adjustmentReason: r.adjustment_reason,
        })),
      },
      200,
    );
  })
  .openapi(enrollRoute, async (c) => {
    const { periodId } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const period = await findPeriod(db, periodId);
    if (period.active !== 1) throw conflict("period_inactive", "Il periodo è disattivato.");
    const now = nowIso();
    // Soci candidati: elenco esplicito oppure gli iscritti di un altro periodo (rinnovo).
    let source: string;
    let params: unknown[];
    if ("memberIds" in body) {
      source = "SELECT value AS id FROM json_each(?3)";
      params = [JSON.stringify([...new Set(body.memberIds)])];
    } else {
      await findPeriod(db, body.renewFromPeriodId);
      source = "SELECT d.member_id AS id FROM dues d WHERE d.course_period_id = ?3 AND d.kind = 'periodo' AND d.cancelled_at IS NULL";
      params = [body.renewFromPeriodId];
    }
    const candidates = await db
      .prepare(
        `SELECT COUNT(*) AS total,
                SUM(CASE WHEN EXISTS (SELECT 1 FROM dues x WHERE x.member_id = m.id AND x.course_period_id = ?1 AND x.kind = 'periodo' AND x.cancelled_at IS NULL) THEN 1 ELSE 0 END) AS already
           FROM members m WHERE m.status = 'attivo' AND m.id IN (${source}) AND ?2 = ?2`,
      )
      .bind(periodId, 0, ...params)
      .first<{ total: number; already: number | null }>();
    if ("memberIds" in body) {
      const existing = await db.prepare("SELECT COUNT(*) AS n FROM members WHERE id IN (SELECT value FROM json_each(?1))").bind(params[0]).first<{ n: number }>();
      if ((existing?.n ?? 0) !== new Set(body.memberIds).size) throw notFound("Uno dei soci indicati non esiste.");
    }
    const res = await db
      .prepare(
        `INSERT INTO dues (member_id, kind, year, month, course_period_id, base_amount_cents, amount_cents, charged_on, created_at, created_by)
         SELECT m.id, 'periodo', ?4, ?5, ?1, ?6, ?6, ?7, ?2, ?8
           FROM members m
          WHERE m.status = 'attivo' AND m.id IN (${source})
            AND NOT EXISTS (SELECT 1 FROM dues x WHERE x.member_id = m.id AND x.course_period_id = ?1 AND x.kind = 'periodo' AND x.cancelled_at IS NULL)`,
      )
      .bind(periodId, now, ...params, yearOf(period.from_period), monthOf(period.from_period), period.amount_cents, todayIso(), me)
      .run();
    const enrolled = res.meta.changes ?? 0;
    await auditStatement(db, me, "create", "enrollment", periodId, { period: `${period.course_name} ${period.name}`, enrolled }).run();
    return c.json({ enrolled, alreadyEnrolled: candidates?.already ?? 0 }, 200);
  });
