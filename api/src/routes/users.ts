import { createRoute, z } from "@hono/zod-openapi";
import { auditStatement } from "../lib/audit.ts";
import { hashPassword } from "../lib/crypto.ts";
import { conflict, notFound } from "../lib/errors.ts";
import { IdParam, bearer, commonErrors, createRouter, errors } from "../lib/http.ts";
import { nowIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { EmailSchema, NewPasswordSchema, USER_COLUMNS, UserSchema, type UserRow, toUser } from "../schemas/users.ts";

const json = <T extends z.ZodType>(schema: T) => ({ content: { "application/json": { schema } } });

const listRoute = createRoute({
  method: "get",
  path: "/users",
  tags: ["Utenti"],
  summary: "Elenco degli utenti dell'app",
  security: bearer,
  responses: {
    200: { description: "Utenti", ...json(z.object({ items: z.array(UserSchema) })) },
    ...commonErrors,
  },
});

const createUserRoute = createRoute({
  method: "post",
  path: "/users",
  tags: ["Utenti"],
  summary: "Crea un utente con password temporanea",
  security: bearer,
  request: {
    body: json(
      z.object({
        email: EmailSchema,
        name: z.string().trim().min(1, "Il nome è obbligatorio.").max(100),
        temporaryPassword: NewPasswordSchema,
      }),
    ),
  },
  responses: { 201: { description: "Utente creato", ...json(UserSchema) }, ...commonErrors, 409: errors[409] },
});

const updateUserRoute = createRoute({
  method: "patch",
  path: "/users/{id}",
  tags: ["Utenti"],
  summary: "Modifica nome, email o stato di un utente",
  security: bearer,
  request: {
    params: IdParam,
    body: json(
      z
        .object({
          email: EmailSchema.optional(),
          name: z.string().trim().min(1).max(100).optional(),
          active: z.boolean().optional(),
        })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: {
    200: { description: "Utente aggiornato", ...json(UserSchema) },
    ...commonErrors,
    404: errors[404],
    409: errors[409],
  },
});

const resetPasswordRoute = createRoute({
  method: "post",
  path: "/users/{id}/password",
  tags: ["Utenti"],
  summary: "Reimposta la password di un altro utente (temporanea, da cambiare al primo accesso)",
  security: bearer,
  request: { params: IdParam, body: json(z.object({ temporaryPassword: NewPasswordSchema })) },
  responses: { 204: { description: "Password reimpostata" }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const revokeSessionsRoute = createRoute({
  method: "post",
  path: "/users/{id}/revoke-sessions",
  tags: ["Utenti"],
  summary: "Chiude tutte le sessioni aperte di un utente",
  security: bearer,
  request: { params: IdParam },
  responses: { 204: { description: "Sessioni chiuse" }, ...commonErrors, 404: errors[404] },
});

async function findUser(db: D1Database, id: number): Promise<UserRow> {
  const row = await db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE id = ?1`).bind(id).first<UserRow>();
  if (!row) throw notFound("Utente non trovato.");
  return row;
}

async function assertEmailFree(db: D1Database, email: string, exceptId = 0) {
  const taken = await db.prepare("SELECT id FROM users WHERE email = ?1 AND id <> ?2").bind(email, exceptId).first();
  if (taken) throw conflict("email_taken", "Esiste già un utente con questa email.");
}

const revokeAll = (db: D1Database, userId: number, now: string) =>
  db.prepare("UPDATE sessions SET revoked_at = ?1 WHERE user_id = ?2 AND revoked_at IS NULL").bind(now, userId);

export const userRoutes = createRouter();
userRoutes.use("/users", requireAuth);
userRoutes.use("/users/*", requireAuth);

userRoutes
  .openapi(listRoute, async (c) => {
    const { results } = await c.env.DB.prepare(`SELECT ${USER_COLUMNS} FROM users ORDER BY name COLLATE NOCASE`).all<UserRow>();
    return c.json({ items: results.map(toUser) }, 200);
  })
  .openapi(createUserRoute, async (c) => {
    const { email, name, temporaryPassword } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user");
    await assertEmailFree(db, email);
    const h = await hashPassword(temporaryPassword, c.env.PASSWORD_PEPPER);
    const now = nowIso();
    const inserted = await db
      .prepare(
        `INSERT INTO users (email, name, password_hash, password_salt, password_iterations,
                            must_change_password, active, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 1, 1, ?6, ?6) RETURNING ${USER_COLUMNS}`,
      )
      .bind(email, name, h.hash, h.salt, h.iterations, now)
      .first<UserRow>();
    await auditStatement(db, me.id, "create", "user", inserted!.id, { name }).run();
    return c.json(toUser(inserted!), 201);
  })
  .openapi(updateUserRoute, async (c) => {
    const { id } = c.req.valid("param");
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user");
    const before = await findUser(db, id);
    if (body.active === false && id === me.id) {
      throw conflict("cannot_deactivate_self", "Non puoi disattivare il tuo stesso utente.");
    }
    if (body.email && body.email !== before.email) await assertEmailFree(db, body.email, id);

    const now = nowIso();
    const statements = [
      db
        .prepare(
          `UPDATE users SET email = COALESCE(?1, email), name = COALESCE(?2, name),
                            active = COALESCE(?3, active), updated_at = ?4 WHERE id = ?5`,
        )
        .bind(body.email ?? null, body.name ?? null, body.active === undefined ? null : Number(body.active), now, id),
      auditStatement(db, me.id, "update", "user", id, {
        before: { name: before.name, active: before.active === 1, emailChanged: false },
        after: { name: body.name ?? before.name, active: body.active ?? before.active === 1, emailChanged: !!body.email && body.email !== before.email },
      }),
    ];
    if (body.active === false) statements.push(revokeAll(db, id, now));
    await db.batch(statements);
    return c.json(toUser(await findUser(db, id)), 200);
  })
  .openapi(resetPasswordRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { temporaryPassword } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user");
    if (id === me.id) {
      throw conflict("use_change_password", "Per la tua password usa la funzione Cambia password.");
    }
    await findUser(db, id);
    const h = await hashPassword(temporaryPassword, c.env.PASSWORD_PEPPER);
    const now = nowIso();
    await db.batch([
      db
        .prepare(
          `UPDATE users SET password_hash = ?1, password_salt = ?2, password_iterations = ?3,
                            must_change_password = 1, updated_at = ?4 WHERE id = ?5`,
        )
        .bind(h.hash, h.salt, h.iterations, now, id),
      revokeAll(db, id, now),
      auditStatement(db, me.id, "password_reset", "user", id),
    ]);
    return c.body(null, 204);
  })
  .openapi(revokeSessionsRoute, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    await findUser(db, id);
    const now = nowIso();
    await db.batch([revokeAll(db, id, now), auditStatement(db, c.get("user").id, "revoke_sessions", "user", id)]);
    return c.body(null, 204);
  });
