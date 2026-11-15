import { createRoute, z } from "@hono/zod-openapi";
import { assertDeletable, USAGE_KINDS, UsageSchema, usageOf } from "../data/usage.ts";
import { auditStatement } from "../lib/audit.ts";
import { IdParam, bearer, commonErrors, createRouter, errors, json } from "../lib/http.ts";
import { requireAuth } from "../middleware/auth.ts";

/**
 * "Dove è usato" ed eliminazione dei dati non usati: soci, prodotti (anche
 * workshop ed eventi), varianti, tariffe, metodi di pagamento e moduli.
 * Corsi, periodi e quote hanno le loro rotte DELETE con la stessa verifica.
 */

const usageRoute = createRoute({
  method: "get",
  path: "/usage/{kind}/{id}",
  tags: ["Eliminazione"],
  summary: "Dove è usato un dato e se si può eliminare",
  security: bearer,
  request: {
    params: z.object({
      kind: z.enum(USAGE_KINDS).openapi({ param: { name: "kind", in: "path" } }),
      id: z.string().min(1).max(40).openapi({ param: { name: "id", in: "path" }, description: "Id numerico, o il codice per i metodi di pagamento" }),
    }),
  },
  responses: { 200: { description: "Utilizzi", ...json(UsageSchema) }, ...commonErrors, 404: errors[404] },
});

const deleted = { 204: { description: "Eliminato" }, ...commonErrors, 404: errors[404], 409: errors[409] };
const del = <P extends z.ZodObject>(path: string, summary: string, params: P) =>
  createRoute({ method: "delete", path, tags: ["Eliminazione"], summary, security: bearer, request: { params }, responses: deleted });

const VariantIdParam = z.object({ variantId: z.coerce.number().int().positive().openapi({ param: { name: "variantId", in: "path" } }) });
const FormIdParam = z.object({ formId: z.coerce.number().int().positive().openapi({ param: { name: "formId", in: "path" } }) });
const CodeParam = z.object({ code: z.string().max(30).openapi({ param: { name: "code", in: "path" } }) });

const deleteMember = del("/members/{id}", "Elimina un socio senza pagamenti (con quote, moduli e sospensioni); i suoi dati personali escono anche dal registro", IdParam);
const deleteProduct = del("/products/{id}", "Elimina un prodotto, workshop o evento senza partecipanti né pagamenti", IdParam);
const deleteVariant = del("/variants/{variantId}", "Elimina una taglia/colore senza acquisti", VariantIdParam);
const deleteCategory = del("/fee-categories/{id}", "Elimina una tariffa che nessun socio e nessuna quota usa", IdParam);
const deleteMethod = del("/payment-methods/{code}", "Elimina un metodo di pagamento mai usato", CodeParam);
const deleteForm = del("/forms/{formId}", "Elimina un modulo che nessuno ha restituito firmato", FormIdParam);

// /members/*, /products/*, /variants/*, /fee-categories/*, /payment-methods/* e
// /forms/* sono già protetti dai rispettivi router (i test lo verificano).
export const usageRoutes = createRouter();
usageRoutes.use("/usage/*", requireAuth);

usageRoutes
  .openapi(usageRoute, async (c) => {
    const { kind, id } = c.req.valid("param");
    return c.json(await usageOf(c.env.DB, kind, id), 200);
  })
  .openapi(deleteMember, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    await assertDeletable(db, "member", id, "member_in_use");
    await db.batch([
      db.prepare("DELETE FROM stock_movements WHERE due_id IN (SELECT id FROM dues WHERE member_id = ?1)").bind(id),
      db.prepare("DELETE FROM dues WHERE member_id = ?1").bind(id),
      db.prepare("DELETE FROM member_forms WHERE member_id = ?1").bind(id),
      db.prepare("DELETE FROM member_suspensions WHERE member_id = ?1").bind(id),
      // GDPR: nel registro restano le operazioni ma non i dati personali del socio.
      db.prepare("UPDATE audit_log SET details = NULL WHERE entity IN ('member', 'suspension') AND (entity_id = ?1 OR json_extract(details, '$.memberId') = ?1)").bind(id),
      db.prepare("DELETE FROM members WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "member", id),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteProduct, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "product", id, "product_in_use");
    await db.batch([
      db.prepare("DELETE FROM stock_movements WHERE variant_id IN (SELECT id FROM product_variants WHERE product_id = ?1)").bind(id),
      db.prepare("DELETE FROM dues WHERE product_id = ?1").bind(id),
      db.prepare("DELETE FROM product_variants WHERE product_id = ?1").bind(id),
      db.prepare("DELETE FROM products WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "product", id, { name: usage.name }),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteVariant, async (c) => {
    const { variantId } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "variant", variantId, "variant_in_use");
    await db.batch([
      db.prepare("DELETE FROM stock_movements WHERE variant_id = ?1").bind(variantId),
      db.prepare("DELETE FROM dues WHERE variant_id = ?1").bind(variantId),
      db.prepare("DELETE FROM product_variants WHERE id = ?1").bind(variantId),
      auditStatement(db, c.get("user").id, "delete", "variant", variantId, { name: usage.name }),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteCategory, async (c) => {
    const { id } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "fee-category", id, "category_in_use");
    await db.batch([
      db.prepare("DELETE FROM dues WHERE category_id = ?1").bind(id),
      db.prepare("DELETE FROM fee_rates WHERE category_id = ?1").bind(id),
      db.prepare("DELETE FROM fee_categories WHERE id = ?1").bind(id),
      auditStatement(db, c.get("user").id, "delete", "fee_category", id, { name: usage.name }),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteMethod, async (c) => {
    const { code } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "payment-method", code, "method_in_use");
    await db.batch([
      db.prepare("DELETE FROM payment_methods WHERE code = ?1").bind(code),
      auditStatement(db, c.get("user").id, "delete", "payment_method", null, { code, label: usage.name }),
    ]);
    return c.body(null, 204);
  })
  .openapi(deleteForm, async (c) => {
    const { formId } = c.req.valid("param");
    const db = c.env.DB;
    const usage = await assertDeletable(db, "form", formId, "form_in_use");
    await db.batch([
      db.prepare("DELETE FROM member_forms WHERE form_id = ?1").bind(formId),
      db.prepare("DELETE FROM forms WHERE id = ?1").bind(formId),
      auditStatement(db, c.get("user").id, "delete", "form", formId, { name: usage.name }),
    ]);
    return c.body(null, 204);
  });
