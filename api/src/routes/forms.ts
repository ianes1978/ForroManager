import { createRoute, z } from "@hono/zod-openapi";
import { auditStatement } from "../lib/audit.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";

const FormSchema = z
  .object({
    id: z.number().int(),
    name: z.string(),
    required: z.boolean(),
    active: z.boolean(),
    delivered: z.number().int().openapi({ description: "Soci a cui è stato consegnato" }),
    returned: z.number().int().openapi({ description: "Soci che l'hanno restituito firmato" }),
  })
  .openapi("Form");

const MemberFormSchema = z
  .object({
    formId: z.number().int(),
    formName: z.string(),
    required: z.boolean(),
    deliveredOn: z.string().nullable(),
    returnedOn: z.string().nullable(),
  })
  .openapi("MemberForm");

const FormMemberSchema = z.object({
  memberId: z.number().int(),
  name: z.string(),
  deliveredOn: z.string(),
  returnedOn: z.string().nullable(),
});

interface FormRow { id: number; name: string; required: number; active: number; delivered: number; returned: number }
const toForm = (r: FormRow) => ({ id: r.id, name: r.name, required: r.required === 1, active: r.active === 1, delivered: r.delivered, returned: r.returned });

const FORM_SELECT = `
  SELECT f.id, f.name, f.required, f.active,
         (SELECT COUNT(*) FROM member_forms mf JOIN members m ON m.id = mf.member_id WHERE mf.form_id = f.id AND m.status = 'attivo') AS delivered,
         (SELECT COUNT(*) FROM member_forms mf JOIN members m ON m.id = mf.member_id WHERE mf.form_id = f.id AND m.status = 'attivo' AND mf.returned_on IS NOT NULL) AS returned
    FROM forms f`;

const FormIdParam = z.object({ formId: z.coerce.number().int().positive().openapi({ param: { name: "formId", in: "path" } }) });

const listRoute = createRoute({
  method: "get", path: "/forms", tags: ["Moduli"], summary: "Moduli con conteggi di consegna e restituzione (soci attivi)", security: bearer,
  responses: { 200: { description: "Moduli", ...json(z.object({ items: z.array(FormSchema) })) }, ...commonErrors },
});
const createFormRoute = createRoute({
  method: "post", path: "/forms", tags: ["Moduli"], summary: "Nuovo modulo", security: bearer,
  request: { body: json(z.object({ name: z.string().trim().min(1, "Il nome è obbligatorio.").max(100), required: z.boolean().default(false) })) },
  responses: { 201: { description: "Creato", ...json(FormSchema) }, ...commonErrors, 409: errors[409] },
});
const updateFormRoute = createRoute({
  method: "patch", path: "/forms/{formId}", tags: ["Moduli"], summary: "Modifica o disattiva un modulo", security: bearer,
  request: {
    params: FormIdParam,
    body: json(
      z.object({ name: z.string().trim().min(1).max(100).optional(), required: z.boolean().optional(), active: z.boolean().optional() })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Aggiornato", ...json(FormSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});
const formMembersRoute = createRoute({
  method: "get", path: "/forms/{formId}/members", tags: ["Moduli"], summary: "Soci attivi a cui è stato consegnato il modulo", security: bearer,
  request: { params: FormIdParam, query: z.object({ missing: z.enum(["true", "false"]).default("false").openapi({ description: "Solo chi deve ancora restituirlo" }) }) },
  responses: { 200: { description: "Soci", ...json(z.object({ items: z.array(FormMemberSchema) })) }, ...commonErrors, 404: errors[404] },
});
const deliverAllRoute = createRoute({
  method: "post", path: "/forms/{formId}/deliver-all", tags: ["Moduli"], summary: "Segna il modulo come consegnato a tutti i soci attivi che non l'hanno ancora", security: bearer,
  request: { params: FormIdParam, body: json(z.object({ deliveredOn: DateSchema.optional() })) },
  responses: { 200: { description: "Esito", ...json(z.object({ delivered: z.number().int() })) }, ...commonErrors, 404: errors[404] },
});
const bulkRoute = createRoute({
  method: "post", path: "/forms/{formId}/members", tags: ["Moduli"], security: bearer,
  summary: "Consegna, segna firmato, rimette da riavere o ritira il modulo per più soci insieme",
  description:
    "deliver: consegna ai soci attivi che non l'hanno ancora. return: segna restituito firmato. unreturn: di nuovo da riavere. " +
    "withdraw: annulla la consegna (registrata per errore); i moduli già firmati non vengono ritirati e sono contati in skipped.",
  request: {
    params: FormIdParam,
    body: json(
      z.object({
        action: z.enum(["deliver", "return", "unreturn", "withdraw"]),
        memberIds: z.array(z.number().int().positive()).min(1, "Scegli almeno un socio.").max(300),
        date: DateSchema.optional().openapi({ description: "Data di consegna o di restituzione (predefinita: oggi)" }),
      }),
    ),
  },
  responses: {
    200: { description: "Esito", ...json(z.object({ changed: z.number().int(), skipped: z.number().int() })) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});
const memberFormsRoute = createRoute({
  method: "get", path: "/members/{id}/forms", tags: ["Moduli"], summary: "Moduli consegnati al socio", security: bearer,
  request: { params: IdParam },
  responses: { 200: { description: "Moduli del socio", ...json(z.object({ items: z.array(MemberFormSchema) })) }, ...commonErrors, 404: errors[404] },
});
const setMemberFormRoute = createRoute({
  method: "put", path: "/members/{id}/forms/{formId}", tags: ["Moduli"],
  summary: "Registra consegna e restituzione firmata di un modulo per il socio",
  description: "delivered=false toglie la consegna (es. registrata per errore). returnedOn=null indica che il modulo non è ancora tornato.",
  security: bearer,
  request: {
    params: IdParam.extend(FormIdParam.shape),
    body: json(z.object({ delivered: z.boolean().default(true), deliveredOn: DateSchema.optional(), returnedOn: DateSchema.nullable().optional() })),
  },
  responses: { 200: { description: "Stato aggiornato", ...json(MemberFormSchema) }, ...commonErrors, 404: errors[404] },
});

async function findForm(db: D1Database, id: number): Promise<FormRow> {
  const row = await db.prepare(`${FORM_SELECT} WHERE f.id = ?1`).bind(id).first<FormRow>();
  if (!row) throw notFound("Modulo non trovato.");
  return row;
}

export const formRoutes = createRouter();
formRoutes.use("/forms", requireAuth);
formRoutes.use("/forms/*", requireAuth);
formRoutes.use("/members/*", requireAuth);

formRoutes
  .openapi(listRoute, async (c) => {
    const { results } = await c.env.DB.prepare(`${FORM_SELECT} ORDER BY f.active DESC, f.name COLLATE NOCASE`).all<FormRow>();
    return c.json({ items: results.map(toForm) }, 200);
  })
  .openapi(createFormRoute, async (c) => {
    const { name, required } = c.req.valid("json");
    const db = c.env.DB;
    if (await db.prepare("SELECT 1 FROM forms WHERE name = ?1 COLLATE NOCASE").bind(name).first()) {
      throw conflict("form_exists", "Esiste già un modulo con questo nome.");
    }
    const row = await db.prepare("INSERT INTO forms (name, required, created_at) VALUES (?1, ?2, ?3) RETURNING id").bind(name, Number(required), nowIso()).first<{ id: number }>();
    await auditStatement(db, c.get("user").id, "create", "form", row!.id, { name, required }).run();
    return c.json(toForm(await findForm(db, row!.id)), 201);
  })
  .openapi(updateFormRoute, async (c) => {
    const { formId } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    await findForm(db, formId);
    if (b.name && (await db.prepare("SELECT 1 FROM forms WHERE name = ?1 COLLATE NOCASE AND id <> ?2").bind(b.name, formId).first())) {
      throw conflict("form_exists", "Esiste già un modulo con questo nome.");
    }
    await db.batch([
      db.prepare("UPDATE forms SET name = COALESCE(?1, name), required = COALESCE(?2, required), active = COALESCE(?3, active) WHERE id = ?4")
        .bind(b.name ?? null, b.required === undefined ? null : Number(b.required), b.active === undefined ? null : Number(b.active), formId),
      auditStatement(db, c.get("user").id, "update", "form", formId, b),
    ]);
    return c.json(toForm(await findForm(db, formId)), 200);
  })
  .openapi(formMembersRoute, async (c) => {
    const { formId } = c.req.valid("param");
    const missing = c.req.valid("query").missing === "true";
    const db = c.env.DB;
    await findForm(db, formId);
    const { results } = await db
      .prepare(
        `SELECT m.id, m.first_name, m.last_name, mf.delivered_on, mf.returned_on
           FROM member_forms mf JOIN members m ON m.id = mf.member_id
          WHERE mf.form_id = ?1 AND m.status = 'attivo' ${missing ? "AND mf.returned_on IS NULL" : ""}
          ORDER BY m.last_name COLLATE NOCASE, m.first_name COLLATE NOCASE`,
      )
      .bind(formId)
      .all<{ id: number; first_name: string; last_name: string; delivered_on: string; returned_on: string | null }>();
    return c.json({ items: results.map((r) => ({ memberId: r.id, name: `${r.last_name} ${r.first_name}`, deliveredOn: r.delivered_on, returnedOn: r.returned_on })) }, 200);
  })
  .openapi(deliverAllRoute, async (c) => {
    const { formId } = c.req.valid("param");
    const { deliveredOn } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const form = await findForm(db, formId);
    if (form.active !== 1) throw conflict("form_inactive", "Il modulo è disattivato.");
    const res = await db
      .prepare(
        `INSERT INTO member_forms (member_id, form_id, delivered_on, updated_at, updated_by)
         SELECT m.id, ?1, ?2, ?3, ?4 FROM members m
          WHERE m.status = 'attivo' AND NOT EXISTS (SELECT 1 FROM member_forms mf WHERE mf.member_id = m.id AND mf.form_id = ?1)`,
      )
      .bind(formId, deliveredOn ?? todayIso(), nowIso(), me)
      .run();
    const delivered = res.meta.changes ?? 0;
    await auditStatement(db, me, "update", "form", formId, { deliverAll: delivered }).run();
    return c.json({ delivered }, 200);
  })
  .openapi(bulkRoute, async (c) => {
    const { formId } = c.req.valid("param");
    const { action, memberIds, date } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const form = await findForm(db, formId);
    const ids = JSON.stringify([...new Set(memberIds)]);
    const day = date ?? todayIso();
    const now = nowIso();
    const inList = "member_id IN (SELECT value FROM json_each(?2))";
    let sql: D1PreparedStatement;
    let skipped = 0;
    switch (action) {
      case "deliver":
        if (form.active !== 1) throw conflict("form_inactive", "Il modulo è disattivato: riattivalo per consegnarlo.");
        sql = db
          .prepare(
            `INSERT INTO member_forms (member_id, form_id, delivered_on, updated_at, updated_by)
             SELECT m.id, ?1, ?3, ?4, ?5 FROM members m
              WHERE m.status = 'attivo' AND m.id IN (SELECT value FROM json_each(?2))
                AND NOT EXISTS (SELECT 1 FROM member_forms x WHERE x.member_id = m.id AND x.form_id = ?1)`,
          )
          .bind(formId, ids, day, now, me);
        break;
      case "return":
        sql = db
          .prepare(`UPDATE member_forms SET returned_on = MAX(?3, delivered_on), updated_at = ?4, updated_by = ?5 WHERE form_id = ?1 AND returned_on IS NULL AND ${inList}`)
          .bind(formId, ids, day, now, me);
        break;
      case "unreturn":
        sql = db
          .prepare(`UPDATE member_forms SET returned_on = NULL, updated_at = ?3, updated_by = ?4 WHERE form_id = ?1 AND returned_on IS NOT NULL AND ${inList}`)
          .bind(formId, ids, now, me);
        break;
      case "withdraw":
        skipped =
          (await db.prepare(`SELECT COUNT(*) AS n FROM member_forms WHERE form_id = ?1 AND returned_on IS NOT NULL AND ${inList}`).bind(formId, ids).first<{ n: number }>())?.n ?? 0;
        sql = db.prepare(`DELETE FROM member_forms WHERE form_id = ?1 AND returned_on IS NULL AND ${inList}`).bind(formId, ids);
        break;
    }
    const [res] = await db.batch([sql, auditStatement(db, me, action === "withdraw" ? "delete" : "update", "member_form", formId, { form: form.name, action, members: memberIds.length })]);
    return c.json({ changed: res?.meta.changes ?? 0, skipped }, 200);
  })
  .openapi(memberFormsRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    if (!(await db.prepare("SELECT 1 FROM members WHERE id = ?1").bind(id).first())) throw notFound("Socio non trovato.");
    const { results } = await db
      .prepare(
        `SELECT f.id AS form_id, f.name, f.required, mf.delivered_on, mf.returned_on
           FROM member_forms mf JOIN forms f ON f.id = mf.form_id
          WHERE mf.member_id = ?1 ORDER BY f.name COLLATE NOCASE`,
      )
      .bind(id)
      .all<{ form_id: number; name: string; required: number; delivered_on: string; returned_on: string | null }>();
    return c.json(
      { items: results.map((r) => ({ formId: r.form_id, formName: r.name, required: r.required === 1, deliveredOn: r.delivered_on, returnedOn: r.returned_on })) },
      200,
    );
  })
  .openapi(setMemberFormRoute, async (c) => {
    const { id, formId } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    if (!(await db.prepare("SELECT 1 FROM members WHERE id = ?1").bind(id).first())) throw notFound("Socio non trovato.");
    const form = await findForm(db, formId);
    const now = nowIso();
    if (!b.delivered) {
      await db.batch([
        db.prepare("DELETE FROM member_forms WHERE member_id = ?1 AND form_id = ?2").bind(id, formId),
        auditStatement(db, me, "update", "member_form", id, { formId, delivered: false }),
      ]);
      return c.json({ formId, formName: form.name, required: form.required === 1, deliveredOn: null, returnedOn: null }, 200);
    }
    const current = await db.prepare("SELECT delivered_on FROM member_forms WHERE member_id = ?1 AND form_id = ?2").bind(id, formId).first<{ delivered_on: string }>();
    const deliveredOn = b.deliveredOn ?? current?.delivered_on ?? todayIso();
    if (b.returnedOn && b.returnedOn < deliveredOn) {
      throw invalid("La restituzione non può precedere la consegna.", [{ field: "returnedOn", message: "Data precedente alla consegna." }]);
    }
    await db.batch([
      db
        .prepare(
          `INSERT INTO member_forms (member_id, form_id, delivered_on, returned_on, updated_at, updated_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
           ON CONFLICT (member_id, form_id) DO UPDATE SET delivered_on = excluded.delivered_on,
             returned_on = CASE WHEN ?7 THEN excluded.returned_on ELSE member_forms.returned_on END,
             updated_at = excluded.updated_at, updated_by = excluded.updated_by`,
        )
        .bind(id, formId, deliveredOn, b.returnedOn ?? null, now, me, b.returnedOn !== undefined ? 1 : 0),
      auditStatement(db, me, "update", "member_form", id, { formId, deliveredOn, returnedOn: b.returnedOn }),
    ]);
    const row = await db.prepare("SELECT delivered_on, returned_on FROM member_forms WHERE member_id = ?1 AND form_id = ?2").bind(id, formId).first<{ delivered_on: string; returned_on: string | null }>();
    return c.json({ formId, formName: form.name, required: form.required === 1, deliveredOn: row!.delivered_on, returnedOn: row!.returned_on }, 200);
  });
