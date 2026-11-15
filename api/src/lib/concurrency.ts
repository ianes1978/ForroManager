import type { Context } from "hono";
import { ApiError } from "./errors.ts";
import type { AppEnv } from "./http.ts";

/** Valore di If-Match per un dato non ancora esistente (es. tariffa non fissata). */
export const VERSION_NONE = "none";

/**
 * Controllo delle modifiche in contemporanea. Il client invia nell'header
 * If-Match la versione (updatedAt) che ha letto; se nel frattempo qualcun altro
 * ha salvato, si risponde 409 "stale" dicendo chi e quando, invece di
 * sovrascrivere. Senza header il controllo non si applica.
 */
export async function assertNotModified(
  c: Context<AppEnv>,
  current: string | null,
  audit: { entity: string; entityId: number },
): Promise<void> {
  const header = c.req.header("If-Match");
  if (!header) return;
  const expected = header.replace(/^W\//, "").replace(/"/g, "").trim();
  if (expected === (current ?? VERSION_NONE)) return;

  const last = await c.env.DB.prepare(
    `SELECT u.name, a.at FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
      WHERE a.entity = ?1 AND a.entity_id = ?2 ORDER BY a.id DESC LIMIT 1`,
  )
    .bind(audit.entity, audit.entityId)
    .first<{ name: string | null; at: string }>();
  const who = last?.name ?? "Qualcun altro";
  const minutes = last ? (Date.now() - Date.parse(last.at)) / 60000 : Infinity;
  const when = minutes < 60 ? "poco fa" : "dopo che li hai aperti";
  throw new ApiError(409, "stale", `${who} ha modificato questi dati ${when}: ricarica e riprova.`, {
    modifiedBy: last?.name ?? null,
    modifiedAt: last?.at ?? current,
  });
}
