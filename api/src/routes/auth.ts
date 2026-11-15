import { createRoute, z } from "@hono/zod-openapi";
import { auditStatement } from "../lib/audit.ts";
import {
  PASSWORD_ITERATIONS,
  hashPassword,
  newSessionToken,
  sha256Base64Url,
  verifyPassword,
} from "../lib/crypto.ts";
import { ApiError, conflict } from "../lib/errors.ts";
import { bearer, commonErrors, createRouter, errors } from "../lib/http.ts";
import { addSeconds, nowIso } from "../lib/time.ts";
import { SESSION_TTL_SECONDS, requireAuth } from "../middleware/auth.ts";
import { EmailSchema, NewPasswordSchema, SessionUserSchema } from "../schemas/users.ts";

/** Dopo questo numero di errori consecutivi l'accesso per quell'email si blocca. */
export const MAX_FAILED_LOGINS = 5;
export const LOCKOUT_SECONDS = 15 * 60;

// Hash fittizio: se l'email non esiste si esegue comunque il calcolo, così il
// tempo di risposta non rivela quali email sono registrate.
const DUMMY_HASH = { hash: "A".repeat(43), salt: "A".repeat(22), iterations: PASSWORD_ITERATIONS };

interface LoginRow {
  id: number;
  email: string;
  name: string;
  password_hash: string;
  password_salt: string;
  password_iterations: number;
  must_change_password: number;
}

const invalidCredentials = () =>
  new ApiError(401, "invalid_credentials", "Email o password non corretti.");

const loginRoute = createRoute({
  method: "post",
  path: "/auth/login",
  tags: ["Accesso"],
  summary: "Accedi con email e password",
  request: {
    body: {
      content: {
        "application/json": {
          schema: z.object({ email: EmailSchema, password: z.string().min(1).max(200) }),
        },
      },
    },
  },
  responses: {
    200: {
      description: "Accesso riuscito",
      content: {
        "application/json": {
          schema: z
            .object({ token: z.string(), expiresAt: z.string(), user: SessionUserSchema })
            .openapi("LoginResult"),
        },
      },
    },
    401: commonErrors[401],
    422: commonErrors[422],
    429: errors[429],
  },
});

const logoutRoute = createRoute({
  method: "post",
  path: "/auth/logout",
  tags: ["Accesso"],
  summary: "Esci e revoca la sessione corrente",
  security: bearer,
  middleware: [requireAuth] as const,
  responses: { 204: { description: "Sessione revocata" }, 401: commonErrors[401] },
});

const meRoute = createRoute({
  method: "get",
  path: "/auth/me",
  tags: ["Accesso"],
  summary: "Utente della sessione corrente",
  security: bearer,
  middleware: [requireAuth] as const,
  responses: {
    200: { description: "Utente corrente", content: { "application/json": { schema: SessionUserSchema } } },
    401: commonErrors[401],
  },
});

const changePasswordRoute = createRoute({
  method: "post",
  path: "/auth/password",
  tags: ["Accesso"],
  summary: "Cambia la propria password (chiude le altre sessioni)",
  security: bearer,
  middleware: [requireAuth] as const,
  request: {
    body: {
      content: {
        "application/json": {
          schema: z.object({ currentPassword: z.string().min(1).max(200), newPassword: NewPasswordSchema }),
        },
      },
    },
  },
  responses: {
    204: { description: "Password aggiornata" },
    401: commonErrors[401],
    409: errors[409],
    422: commonErrors[422],
  },
});

export const authRoutes = createRouter()
  .openapi(loginRoute, async (c) => {
    const { email, password } = c.req.valid("json");
    const db = c.env.DB;
    const pepper = c.env.PASSWORD_PEPPER;
    const emailHash = await sha256Base64Url(email);
    const now = nowIso();
    const windowStart = addSeconds(now, -LOCKOUT_SECONDS);

    // Errori recenti dopo l'ultimo accesso riuscito.
    const recent = await db
      .prepare(
        `SELECT COUNT(*) AS n FROM login_attempts
          WHERE email_hash = ?1 AND success = 0 AND attempted_at > ?2
            AND attempted_at > COALESCE(
              (SELECT MAX(attempted_at) FROM login_attempts WHERE email_hash = ?1 AND success = 1), '')`,
      )
      .bind(emailHash, windowStart)
      .first<{ n: number }>();
    if ((recent?.n ?? 0) >= MAX_FAILED_LOGINS) {
      throw new ApiError(
        429,
        "too_many_attempts",
        "Troppi tentativi non riusciti. Riprova tra 15 minuti o chiedi a un altro utente di reimpostare la password.",
      );
    }

    const user = await db
      .prepare(
        `SELECT id, email, name, password_hash, password_salt, password_iterations, must_change_password
           FROM users WHERE email = ?1 AND active = 1`,
      )
      .bind(email)
      .first<LoginRow>();

    const stored = user
      ? { hash: user.password_hash, salt: user.password_salt, iterations: user.password_iterations }
      : DUMMY_HASH;
    const ok = (await verifyPassword(password, pepper, stored)) && user !== null;

    const recordAttempt = db
      .prepare("INSERT INTO login_attempts (email_hash, attempted_at, success) VALUES (?1, ?2, ?3)")
      .bind(emailHash, now, ok ? 1 : 0);

    if (!ok || !user) {
      await recordAttempt.run();
      throw invalidCredentials();
    }

    const token = newSessionToken();
    const expiresAt = addSeconds(now, SESSION_TTL_SECONDS);
    const statements = [
      recordAttempt,
      db
        .prepare(
          "INSERT INTO sessions (token_hash, user_id, created_at, expires_at, last_used_at) VALUES (?1, ?2, ?3, ?4, ?3)",
        )
        .bind(await sha256Base64Url(token), user.id, now, expiresAt),
      // Pulizia: tentativi più vecchi di un giorno e sessioni scadute da tempo.
      db.prepare("DELETE FROM login_attempts WHERE attempted_at < ?1").bind(addSeconds(now, -86400)),
      db.prepare("DELETE FROM sessions WHERE expires_at < ?1").bind(addSeconds(now, -SESSION_TTL_SECONDS)),
    ];
    // Se le iterazioni configurate sono aumentate, si aggiorna l'hash ora che la password è nota.
    if (user.password_iterations < PASSWORD_ITERATIONS) {
      const h = await hashPassword(password, pepper);
      statements.push(
        db
          .prepare(
            "UPDATE users SET password_hash = ?1, password_salt = ?2, password_iterations = ?3, updated_at = ?4 WHERE id = ?5",
          )
          .bind(h.hash, h.salt, h.iterations, now, user.id),
      );
    }
    await db.batch(statements);

    return c.json(
      {
        token,
        expiresAt,
        user: { id: user.id, email: user.email, name: user.name, mustChangePassword: user.must_change_password === 1 },
      },
      200,
    );
  })
  .openapi(logoutRoute, async (c) => {
    await c.env.DB.prepare("UPDATE sessions SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL")
      .bind(nowIso(), c.get("sessionId"))
      .run();
    return c.body(null, 204);
  })
  .openapi(meRoute, (c) => c.json(c.get("user"), 200))
  .openapi(changePasswordRoute, async (c) => {
    const { currentPassword, newPassword } = c.req.valid("json");
    const me = c.get("user");
    const db = c.env.DB;
    const pepper = c.env.PASSWORD_PEPPER;

    const row = await db
      .prepare("SELECT password_hash, password_salt, password_iterations FROM users WHERE id = ?1")
      .bind(me.id)
      .first<{ password_hash: string; password_salt: string; password_iterations: number }>();
    const valid =
      row &&
      (await verifyPassword(currentPassword, pepper, {
        hash: row.password_hash,
        salt: row.password_salt,
        iterations: row.password_iterations,
      }));
    if (!valid) throw new ApiError(401, "invalid_credentials", "La password attuale non è corretta.");
    if (currentPassword === newPassword) {
      throw conflict("same_password", "La nuova password deve essere diversa da quella attuale.");
    }

    const h = await hashPassword(newPassword, pepper);
    const now = nowIso();
    await db.batch([
      db
        .prepare(
          `UPDATE users SET password_hash = ?1, password_salt = ?2, password_iterations = ?3,
                            must_change_password = 0, updated_at = ?4 WHERE id = ?5`,
        )
        .bind(h.hash, h.salt, h.iterations, now, me.id),
      db
        .prepare("UPDATE sessions SET revoked_at = ?1 WHERE user_id = ?2 AND id <> ?3 AND revoked_at IS NULL")
        .bind(now, me.id, c.get("sessionId")),
      auditStatement(db, me.id, "password_change", "user", me.id),
    ]);
    return c.body(null, 204);
  });
