import { createMiddleware } from "hono/factory";
import { ApiError, conflict } from "../lib/errors.ts";
import type { AppEnv } from "../lib/http.ts";
import { addSeconds, nowIso } from "../lib/time.ts";

const KEY_TTL_SECONDS = 24 * 3600;

/**
 * Rende ripetibili senza effetti doppi le operazioni POST che registrano soldi o
 * merce. Il client manda "Idempotency-Key: <valore casuale>" e lo riusa se
 * ripete la stessa operazione. Va montato dopo requireAuth.
 *
 * - chiave nuova: si esegue l'operazione; se riesce (2xx) la risposta viene salvata;
 * - chiave già completata: si restituisce la risposta salvata (header Idempotent-Replayed);
 * - chiave ancora in corso: 409, si riprova tra poco;
 * - operazione fallita: la chiave viene liberata e si può riprovare.
 */
export const idempotent = createMiddleware<AppEnv>(async (c, next) => {
  const key = c.req.header("Idempotency-Key");
  if (!key) return next();
  if (!/^[A-Za-z0-9_-]{16,100}$/.test(key)) {
    throw new ApiError(400, "invalid_idempotency_key", "Chiave di operazione non valida.");
  }
  const db = c.env.DB;
  const userId = c.get("user").id;
  const route = `${c.req.method} ${c.req.path}`;
  const now = nowIso();

  const reserved = await db
    .prepare("INSERT INTO idempotency_keys (key, user_id, route, created_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (key) DO NOTHING")
    .bind(key, userId, route, now)
    .run();

  if (!reserved.meta.changes) {
    const prev = await db
      .prepare("SELECT user_id, route, status_code, response_body FROM idempotency_keys WHERE key = ?1")
      .bind(key)
      .first<{ user_id: number; route: string; status_code: number | null; response_body: string | null }>();
    if (!prev || prev.user_id !== userId || prev.route !== route) {
      throw new ApiError(422, "idempotency_key_reused", "Chiave di operazione già usata per un'altra operazione.");
    }
    if (prev.status_code === null) {
      throw conflict("operation_in_progress", "Questa operazione è già in corso: attendi qualche secondo e riprova.");
    }
    return new Response(prev.response_body, {
      status: prev.status_code,
      headers: { "Content-Type": "application/json", "Idempotent-Replayed": "true" },
    });
  }

  let ok = false;
  try {
    await next();
    ok = c.res.status >= 200 && c.res.status < 300 && !c.error;
  } finally {
    if (ok) {
      const body = await c.res.clone().text();
      await db.batch([
        db.prepare("UPDATE idempotency_keys SET status_code = ?1, response_body = ?2 WHERE key = ?3").bind(c.res.status, body, key),
        db.prepare("DELETE FROM idempotency_keys WHERE created_at < ?1").bind(addSeconds(now, -KEY_TTL_SECONDS)),
      ]);
    } else {
      await db.prepare("DELETE FROM idempotency_keys WHERE key = ?1").bind(key).run();
    }
  }
});
