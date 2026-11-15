import { createRoute, z } from "@hono/zod-openapi";
import { bearer, commonErrors, createRouter, json } from "../lib/http.ts";
import { requireAuth } from "../middleware/auth.ts";

const AuditEntrySchema = z
  .object({
    id: z.number().int(),
    at: z.string(),
    user: z.object({ id: z.number().int(), name: z.string() }).nullable(),
    action: z.string(),
    entity: z.string(),
    entityId: z.number().int().nullable(),
    description: z.string().openapi({ example: "ha registrato un pagamento" }),
    details: z.unknown(),
  })
  .openapi("AuditEntry");

const ENTITY_LABELS: Record<string, string> = {
  member: "un socio",
  payment: "un pagamento",
  due: "una quota",
  dues: "le quote",
  fee_rate: "una tariffa",
  fee_category: "una categoria di tariffa",
  product: "un prodotto",
  user: "un utente",
  suspension: "una sospensione",
  form: "un modulo",
  member_form: "un modulo di un socio",
  payment_method: "un metodo di pagamento",
  variant: "una variante di prodotto",
  stock: "le scorte di magazzino",
  course: "un corso",
  course_period: "un periodo di corso",
  enrollment: "le iscrizioni a un periodo",
};
const ACTION_LABELS: Record<string, string> = {
  create: "ha creato",
  update: "ha modificato",
  void: "ha annullato",
  cancel: "ha annullato",
  cease: "ha cessato",
  generate: "ha generato",
  password_change: "ha cambiato la propria password",
  password_reset: "ha reimpostato la password di",
  revoke_sessions: "ha chiuso le sessioni di",
  delete: "ha eliminato",
};

export function describeAudit(action: string, entity: string): string {
  if (action === "password_change") return ACTION_LABELS.password_change!;
  if (action === "create" && entity === "payment") return "ha registrato un pagamento";
  return `${ACTION_LABELS[action] ?? action} ${ENTITY_LABELS[entity] ?? entity}`;
}

const listRoute = createRoute({
  method: "get",
  path: "/audit",
  tags: ["Registro modifiche"],
  summary: "Registro delle modifiche, dal più recente",
  security: bearer,
  request: {
    query: z.object({
      entity: z.string().max(30).optional(),
      entityId: z.coerce.number().int().positive().optional(),
      beforeId: z.coerce.number().int().positive().optional().openapi({ description: "Per caricare le voci precedenti" }),
      limit: z.coerce.number().int().min(1).max(200).default(50),
    }),
  },
  responses: { 200: { description: "Voci del registro", ...json(z.object({ items: z.array(AuditEntrySchema) })) }, ...commonErrors },
});

export const auditRoutes = createRouter();
auditRoutes.use("/audit", requireAuth);

auditRoutes.openapi(listRoute, async (c) => {
  const q = c.req.valid("query");
  const where: string[] = [];
  const params: unknown[] = [];
  const add = (sql: string, v: unknown) => {
    params.push(v);
    where.push(sql.replace("?", `?${params.length}`));
  };
  if (q.entity) add("a.entity = ?", q.entity);
  if (q.entityId) add("a.entity_id = ?", q.entityId);
  if (q.beforeId) add("a.id < ?", q.beforeId);
  params.push(q.limit);
  const { results } = await c.env.DB.prepare(
    `SELECT a.id, a.at, a.user_id, u.name AS user_name, a.action, a.entity, a.entity_id, a.details
       FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
       ${where.length ? `WHERE ${where.join(" AND ")}` : ""}
      ORDER BY a.id DESC LIMIT ?${params.length}`,
  )
    .bind(...params)
    .all<{ id: number; at: string; user_id: number | null; user_name: string | null; action: string; entity: string; entity_id: number | null; details: string | null }>();
  return c.json(
    {
      items: results.map((r) => ({
        id: r.id,
        at: r.at,
        user: r.user_id ? { id: r.user_id, name: r.user_name ?? "" } : null,
        action: r.action,
        entity: r.entity,
        entityId: r.entity_id,
        description: describeAudit(r.action, r.entity),
        details: r.details ? JSON.parse(r.details) : null,
      })),
    },
    200,
  );
});
