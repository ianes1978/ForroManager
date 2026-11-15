import { createMiddleware } from "hono/factory";
import { sha256Base64Url } from "../lib/crypto.ts";
import { forbidden, unauthorized } from "../lib/errors.ts";
import type { AppEnv } from "../lib/http.ts";
import { addSeconds, nowIso } from "../lib/time.ts";

/** Durata della sessione, rinnovata a ogni uso (scadenza "scorrevole"). */
export const SESSION_TTL_SECONDS = 30 * 24 * 3600;
/** Il rinnovo si scrive al massimo una volta l'ora, per risparmiare scritture su D1. */
const RENEW_AFTER_SECONDS = 3600;

/** Percorsi consentiti anche a chi deve ancora cambiare la password temporanea. */
const ALLOWED_WITH_TEMP_PASSWORD = new Set(["/api/v1/auth/me", "/api/v1/auth/password", "/api/v1/auth/logout"]);

interface SessionRow {
  session_id: number;
  expires_at: string;
  last_used_at: string;
  revoked_at: string | null;
  user_id: number;
  email: string;
  name: string;
  active: number;
  must_change_password: number;
}

export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9_-]{20,100})$/.exec(header);
  if (!match) throw unauthorized("Accesso richiesto.");

  const tokenHash = await sha256Base64Url(match[1]!);
  const row = await c.env.DB.prepare(
    `SELECT s.id AS session_id, s.expires_at, s.last_used_at, s.revoked_at,
            u.id AS user_id, u.email, u.name, u.active, u.must_change_password
       FROM sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ?1`,
  )
    .bind(tokenHash)
    .first<SessionRow>();

  const now = nowIso();
  if (!row || row.revoked_at || row.expires_at <= now || row.active !== 1) throw unauthorized();

  if (Date.parse(now) - Date.parse(row.last_used_at) > RENEW_AFTER_SECONDS * 1000) {
    await c.env.DB.prepare("UPDATE sessions SET last_used_at = ?1, expires_at = ?2 WHERE id = ?3")
      .bind(now, addSeconds(now, SESSION_TTL_SECONDS), row.session_id)
      .run();
  }

  const mustChange = row.must_change_password === 1;
  if (mustChange && !ALLOWED_WITH_TEMP_PASSWORD.has(c.req.path)) {
    throw forbidden("password_change_required", "Prima di continuare devi cambiare la password temporanea.");
  }

  c.set("user", { id: row.user_id, email: row.email, name: row.name, mustChangePassword: mustChange });
  c.set("sessionId", row.session_id);
  await next();
});
