import { nowIso } from "./time.ts";

export type AuditAction =
  | "create"
  | "update"
  | "void"
  | "cancel"
  | "cease"
  | "generate"
  | "password_change"
  | "password_reset"
  | "revoke_sessions"
  | "delete";

/**
 * Prepara una riga del registro modifiche, da eseguire nello stesso batch
 * dell'operazione che descrive.
 */
export function auditStatement(
  db: D1Database,
  userId: number | null,
  action: AuditAction,
  entity: string,
  entityId: number | null,
  details?: Record<string, unknown>,
): D1PreparedStatement {
  return db
    .prepare("INSERT INTO audit_log (at, user_id, action, entity, entity_id, details) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
    .bind(nowIso(), userId, action, entity, entityId, details ? JSON.stringify(details) : null);
}
