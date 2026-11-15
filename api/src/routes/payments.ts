import { createRoute, z } from "@hono/zod-openapi";
import { type DueRow, VARIANT_LABEL_SQL, memberDues } from "../data/dues.ts";
import { restockStatement } from "../data/sales.ts";
import { allocate, compareForAllocation, dueLabel, type DueKind, splitCents } from "../domain/dues.ts";
import { isSuspended, periodOf } from "../domain/periods.ts";
import { auditStatement } from "../lib/audit.ts";
import { conflict, invalid, notFound } from "../lib/errors.ts";
import { DateSchema, IdParam, bearer, commonErrors, createRouter, errors, IdempotencyHeaders, json } from "../lib/http.ts";
import { nowIso, todayIso } from "../lib/time.ts";
import { requireAuth } from "../middleware/auth.ts";
import { idempotent } from "../middleware/idempotency.ts";

// ---------------------------------------------------------------------------
// Schemi
// ---------------------------------------------------------------------------
const MethodSchema = z.object({ code: z.string(), label: z.string(), active: z.boolean() }).openapi("PaymentMethod");

const AllocationSchema = z.object({ dueId: z.number().int(), label: z.string(), amountCents: z.number().int() });

export const PaymentSchema = z
  .object({
    id: z.number().int(),
    memberId: z.number().int().nullable(),
    memberName: z.string().openapi({ description: "Nome del socio oppure \"Non socio\"" }),
    paidOn: z.string(),
    amountCents: z.number().int(),
    method: z.object({ code: z.string(), label: z.string() }),
    note: z.string().nullable(),
    recordedBy: z.object({ id: z.number().int(), name: z.string() }),
    createdAt: z.string(),
    voided: z.boolean(),
    voidedAt: z.string().nullable(),
    voidReason: z.string().nullable(),
    allocations: z.array(AllocationSchema),
    description: z.string().openapi({ example: "Mensili ottobre–dicembre 2026" }),
  })
  .openapi("Payment");

const ItemSchema = z.union([
  z.object({ dueId: z.number().int().positive() }),
  z.object({ year: z.number().int().min(2000).max(2100), month: z.number().int().min(1).max(12) }),
]);

const CreatePaymentSchema = z.object({
  memberId: z.number().int().positive(),
  paidOn: DateSchema.optional(),
  amountCents: z.number().int("L'importo va indicato in centesimi.").positive("L'importo deve essere maggiore di zero.").max(10_000_000),
  method: z.string().min(1).max(30).openapi({ example: "contanti" }),
  note: z.string().trim().max(500).optional(),
  items: z
    .array(ItemSchema)
    .min(1, "Scegli almeno una voce da pagare.")
    .max(12, "Al massimo 12 voci per pagamento.")
    .openapi({ description: "Quote esistenti ({dueId}) o mesi da creare al momento ({year, month}), ad esempio per pagare in anticipo." }),
  packageCategoryId: z.number().int().positive().optional().openapi({ description: "Applica il prezzo di un pacchetto ai mesi scelti" }),
});

// ---------------------------------------------------------------------------
// Lettura
// ---------------------------------------------------------------------------
interface PaymentRow {
  id: number;
  member_id: number | null;
  first_name: string | null;
  last_name: string | null;
  paid_on: string;
  amount_cents: number;
  method_code: string;
  method_label: string;
  note: string | null;
  recorded_by: number;
  recorded_by_name: string;
  created_at: string;
  voided_at: string | null;
  void_reason: string | null;
}

interface AllocationRow {
  payment_id: number;
  due_id: number;
  amount_cents: number;
  kind: DueKind;
  year: number;
  month: number | null;
  product_name: string | null;
  variant_label: string | null;
  quantity: number;
}

const PAYMENT_SELECT = `
  SELECT p.id, p.member_id, m.first_name, m.last_name, p.paid_on, p.amount_cents,
         pm.code AS method_code, pm.label AS method_label, p.note, p.recorded_by, u.name AS recorded_by_name,
         p.created_at, p.voided_at, p.void_reason
    FROM payments p
    LEFT JOIN members m ON m.id = p.member_id
    JOIN payment_methods pm ON pm.id = p.method_id
    JOIN users u ON u.id = p.recorded_by`;

const ALLOCATION_SELECT = `
  SELECT a.payment_id, a.due_id, a.amount_cents, d.kind, d.year, d.month, pr.name AS product_name,
         ${VARIANT_LABEL_SQL} AS variant_label, d.quantity
    FROM payment_allocations a
    JOIN dues d ON d.id = a.due_id
    LEFT JOIN products pr ON pr.id = d.product_id
    LEFT JOIN product_variants v ON v.id = d.variant_id`;

const MESI_BREVI = ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"];
const MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"];

/** Descrizione breve: "Mensile luglio 2026", "Mensili ott 2026–gen 2027", "Quota associativa 2026 + 2 mensili"... */
export function describeAllocations(
  allocs: (Pick<AllocationRow, "kind" | "year" | "month" | "product_name"> & Partial<Pick<AllocationRow, "variant_label" | "quantity">>)[],
): string {
  if (allocs.length === 1) {
    const a = allocs[0]!;
    return dueLabel({ kind: a.kind, year: a.year, month: a.month, productName: a.product_name, variantLabel: a.variant_label, quantity: a.quantity });
  }
  const months = allocs.filter((a) => a.kind === "mensile").sort((a, b) => periodOf(a.year, a.month!) - periodOf(b.year, b.month!));
  const parts: string[] = [];
  for (const a of allocs.filter((x) => x.kind === "annuale")) parts.push(`Quota associativa ${a.year}`);
  if (months.length === 1) parts.push(`Mensile ${MESI[months[0]!.month! - 1]} ${months[0]!.year}`);
  if (months.length > 1) {
    const f = months[0]!, l = months[months.length - 1]!;
    parts.push(f.year === l.year ? `Mensili ${MESI_BREVI[f.month! - 1]}–${MESI_BREVI[l.month! - 1]} ${l.year}` : `Mensili ${MESI_BREVI[f.month! - 1]} ${f.year}–${MESI_BREVI[l.month! - 1]} ${l.year}`);
  }
  for (const a of allocs.filter((x) => x.kind === "prodotto")) {
    parts.push(dueLabel({ kind: "prodotto", year: a.year, month: null, productName: a.product_name, variantLabel: a.variant_label, quantity: a.quantity }));
  }
  return parts.join(" + ");
}

function toPayment(r: PaymentRow, allocs: AllocationRow[]): z.infer<typeof PaymentSchema> {
  return {
    id: r.id,
    memberId: r.member_id,
    memberName: r.member_id === null ? "Non socio" : `${r.last_name} ${r.first_name}`,
    paidOn: r.paid_on,
    amountCents: r.amount_cents,
    method: { code: r.method_code, label: r.method_label },
    note: r.note,
    recordedBy: { id: r.recorded_by, name: r.recorded_by_name },
    createdAt: r.created_at,
    voided: r.voided_at !== null,
    voidedAt: r.voided_at,
    voidReason: r.void_reason,
    allocations: allocs.map((a) => ({
      dueId: a.due_id,
      label: dueLabel({ kind: a.kind, year: a.year, month: a.month, productName: a.product_name, variantLabel: a.variant_label, quantity: a.quantity }),
      amountCents: a.amount_cents,
    })),
    description: describeAllocations(allocs),
  };
}

async function findPayment(db: D1Database, id: number) {
  const [row, allocs] = await Promise.all([
    db.prepare(`${PAYMENT_SELECT} WHERE p.id = ?1`).bind(id).first<PaymentRow>(),
    db.prepare(`${ALLOCATION_SELECT} WHERE a.payment_id = ?1 ORDER BY a.id`).bind(id).all<AllocationRow>(),
  ]);
  if (!row) throw notFound("Pagamento non trovato.");
  return toPayment(row, allocs.results);
}

// ---------------------------------------------------------------------------
// Rotte
// ---------------------------------------------------------------------------
const listRoute = createRoute({
  method: "get",
  path: "/payments",
  tags: ["Pagamenti"],
  summary: "Pagamenti per periodo, socio o metodo (più recenti prima)",
  security: bearer,
  request: {
    query: z.object({
      from: DateSchema.optional(),
      to: DateSchema.optional(),
      memberId: z.coerce.number().int().positive().optional(),
      method: z.string().max(30).optional(),
      limit: z.coerce.number().int().min(1).max(500).default(200),
    }),
  },
  responses: { 200: { description: "Pagamenti", ...json(z.object({ items: z.array(PaymentSchema) })) }, ...commonErrors },
});

const getRoute = createRoute({
  method: "get",
  path: "/payments/{id}",
  tags: ["Pagamenti"],
  summary: "Dettaglio di un pagamento",
  security: bearer,
  request: { params: IdParam },
  responses: { 200: { description: "Pagamento", ...json(PaymentSchema) }, ...commonErrors, 404: errors[404] },
});

const createPaymentRoute = createRoute({
  method: "post",
  path: "/payments",
  tags: ["Pagamenti"],
  summary: "Registra un pagamento su una o più voci",
  description:
    "Le voci vengono coperte in ordine (associativa, mesi in ordine, prodotti). Un importo inferiore al totale copre prima le voci più vecchie.",
  security: bearer,
  middleware: [idempotent] as const,
  request: {
    headers: IdempotencyHeaders, body: json(CreatePaymentSchema) },
  responses: { 201: { description: "Pagamento registrato", ...json(PaymentSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const voidRoute = createRoute({
  method: "post",
  path: "/payments/{id}/void",
  tags: ["Pagamenti"],
  summary: "Annulla un pagamento (resta visibile come annullato)",
  security: bearer,
  request: { params: IdParam, body: json(z.object({ reason: z.string().trim().min(1, "Indica il motivo.").max(200) })) },
  responses: { 200: { description: "Pagamento annullato", ...json(PaymentSchema) }, ...commonErrors, 404: errors[404], 409: errors[409] },
});

const methodsRoute = createRoute({
  method: "get",
  path: "/payment-methods",
  tags: ["Pagamenti"],
  summary: "Metodi di pagamento",
  security: bearer,
  responses: { 200: { description: "Metodi", ...json(z.object({ items: z.array(MethodSchema) })) }, ...commonErrors },
});

const createMethodRoute = createRoute({
  method: "post",
  path: "/payment-methods",
  tags: ["Pagamenti"],
  summary: "Aggiunge un metodo di pagamento",
  security: bearer,
  request: { body: json(z.object({ label: z.string().trim().min(1, "Il nome è obbligatorio.").max(30) })) },
  responses: { 201: { description: "Metodo creato", ...json(MethodSchema) }, ...commonErrors, 409: errors[409] },
});

const updateMethodRoute = createRoute({
  method: "patch",
  path: "/payment-methods/{code}",
  tags: ["Pagamenti"],
  summary: "Rinomina o disattiva un metodo di pagamento",
  security: bearer,
  request: {
    params: z.object({ code: z.string().max(30).openapi({ param: { name: "code", in: "path" } }) }),
    body: json(
      z
        .object({ label: z.string().trim().min(1).max(30).optional(), active: z.boolean().optional() })
        .refine((v) => Object.keys(v).length > 0, "Nessuna modifica indicata."),
    ),
  },
  responses: { 200: { description: "Metodo aggiornato", ...json(MethodSchema) }, ...commonErrors, 404: errors[404] },
});

interface Planned {
  /** Quota esistente o null se va creata. */
  existing: DueRow | null;
  kind: DueKind;
  year: number;
  month: number | null;
  chargedOn: string;
  sortId: number;
  categoryId: number | null;
  baseAmountCents: number;
  amountCents: number;
  paidCents: number;
  adjustmentReason: string | null;
  label: string;
}

const slug = (label: string) =>
  label
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "")
    .slice(0, 30) || "metodo";

export const paymentRoutes = createRouter();
paymentRoutes.use("/payments", requireAuth);
paymentRoutes.use("/payments/*", requireAuth);
paymentRoutes.use("/payment-methods", requireAuth);
paymentRoutes.use("/payment-methods/*", requireAuth);

paymentRoutes
  .openapi(listRoute, async (c) => {
    const q = c.req.valid("query");
    const where: string[] = [];
    const params: unknown[] = [];
    const add = (sql: string, value: unknown) => {
      params.push(value);
      where.push(sql.replace("?", `?${params.length}`));
    };
    if (q.from) add("p.paid_on >= ?", q.from);
    if (q.to) add("p.paid_on <= ?", q.to);
    if (q.memberId) add("p.member_id = ?", q.memberId);
    if (q.method) add("p.method_id = (SELECT id FROM payment_methods WHERE code = ?)", q.method);
    const filter = where.length ? `WHERE ${where.join(" AND ")}` : "";
    params.push(q.limit);
    const limit = `?${params.length}`;
    const db = c.env.DB;
    const [rows, allocs] = await db.batch([
      db.prepare(`${PAYMENT_SELECT} ${filter} ORDER BY p.paid_on DESC, p.id DESC LIMIT ${limit}`).bind(...params),
      db
        .prepare(
          `${ALLOCATION_SELECT} WHERE a.payment_id IN (SELECT p.id FROM payments p ${filter} ORDER BY p.paid_on DESC, p.id DESC LIMIT ${limit}) ORDER BY a.id`,
        )
        .bind(...params),
    ]);
    const byPayment = new Map<number, AllocationRow[]>();
    for (const a of allocs!.results as unknown as AllocationRow[]) {
      byPayment.set(a.payment_id, [...(byPayment.get(a.payment_id) ?? []), a]);
    }
    const items = (rows!.results as unknown as PaymentRow[]).map((r) => toPayment(r, byPayment.get(r.id) ?? []));
    return c.json({ items }, 200);
  })
  .openapi(getRoute, async (c) => c.json(await findPayment(c.env.DB, c.req.valid("param").id), 200))
  .openapi(createPaymentRoute, async (c) => {
    const body = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const today = todayIso();
    const paidOn = body.paidOn ?? today;

    const member = await db
      .prepare("SELECT id, status, monthly_category_id FROM members WHERE id = ?1")
      .bind(body.memberId)
      .first<{ id: number; status: string; monthly_category_id: number }>();
    if (!member) throw notFound("Socio non trovato.");
    const method = await db
      .prepare("SELECT id FROM payment_methods WHERE code = ?1 AND active = 1")
      .bind(body.method)
      .first<{ id: number }>();
    if (!method) throw invalid("Metodo di pagamento non valido.", [{ field: "method", message: "Scegli un metodo attivo." }]);

    const dues = await memberDues(db, member.id);
    const suspensions = (
      await db
        .prepare("SELECT from_period AS f, to_period AS t FROM member_suspensions WHERE member_id = ?1 AND cancelled_at IS NULL")
        .bind(member.id)
        .all<{ f: number; t: number }>()
    ).results.map((s) => ({ from: s.f, to: s.t }));

    // 1. Risolve le voci richieste.
    const planned: Planned[] = [];
    const seen = new Set<string>();
    for (const item of body.items) {
      if ("dueId" in item) {
        const due = dues.find((d) => d.id === item.dueId);
        if (!due) throw notFound("Una delle quote scelte non esiste o non appartiene al socio.");
        if (seen.has(`d${due.id}`) || (due.month && seen.has(`m${due.year}-${due.month}`))) throw invalid("Hai scelto due volte la stessa voce.");
        seen.add(`d${due.id}`);
        if (due.month) seen.add(`m${due.year}-${due.month}`);
        if (due.paid_cents >= due.amount_cents) throw conflict("due_already_paid", "Una delle quote scelte è già pagata.");
        planned.push({
          existing: due,
          kind: due.kind,
          year: due.year,
          month: due.month,
          chargedOn: due.charged_on,
          sortId: due.id,
          categoryId: due.category_id,
          baseAmountCents: due.base_amount_cents,
          amountCents: due.amount_cents,
          paidCents: due.paid_cents,
          adjustmentReason: due.adjustment_reason,
          label: dueLabel({ kind: due.kind, year: due.year, month: due.month, productName: due.product_name }),
        });
      } else {
        const key = `m${item.year}-${item.month}`;
        if (seen.has(key)) throw invalid("Hai scelto due volte lo stesso mese.");
        seen.add(key);
        const label = dueLabel({ kind: "mensile", year: item.year, month: item.month });
        const existing = dues.find((d) => d.kind === "mensile" && d.year === item.year && d.month === item.month);
        if (existing) throw conflict("due_exists", `${label} esiste già: sceglila dall'elenco delle quote.`);
        if (member.status !== "attivo") throw conflict("member_ceased", "Il socio è cessato: non si possono creare nuove quote.");
        if (isSuspended(periodOf(item.year, item.month), suspensions)) throw conflict("suspended_month", `${label}: il socio è sospeso.`);
        const rate = await db
          .prepare("SELECT amount_cents FROM fee_rates WHERE category_id = ?1 AND year = ?2")
          .bind(member.monthly_category_id, item.year)
          .first<{ amount_cents: number }>();
        if (!rate) throw invalid(`Manca l'importo della quota mensile per il ${item.year}.`, [{ field: "items", message: "Tariffa mancante." }]);
        planned.push({
          existing: null,
          kind: "mensile",
          year: item.year,
          month: item.month,
          chargedOn: paidOn,
          sortId: Number.MAX_SAFE_INTEGER,
          categoryId: member.monthly_category_id,
          baseAmountCents: rate.amount_cents,
          amountCents: rate.amount_cents,
          paidCents: 0,
          adjustmentReason: null,
          label,
        });
      }
    }
    planned.sort((a, b) =>
      compareForAllocation(
        { kind: a.kind, year: a.year, month: a.month, chargedOn: a.chargedOn, id: a.sortId },
        { kind: b.kind, year: b.year, month: b.month, chargedOn: b.chargedOn, id: b.sortId },
      ),
    );

    // 2. Pacchetto: prezzo complessivo ripartito sui mesi scelti.
    const adjusted = new Set<Planned>();
    if (body.packageCategoryId) {
      const pkg = await db
        .prepare("SELECT id, name, months FROM fee_categories WHERE id = ?1 AND kind = 'pacchetto' AND active = 1")
        .bind(body.packageCategoryId)
        .first<{ id: number; name: string; months: number }>();
      if (!pkg) throw invalid("Pacchetto non valido.", [{ field: "packageCategoryId", message: "Scegli un pacchetto attivo." }]);
      const months = planned.filter((p) => p.kind === "mensile");
      if (months.length !== pkg.months) {
        throw conflict("package_not_applicable", `Il pacchetto ${pkg.name} vale per ${pkg.months} mesi: ne hai scelti ${months.length}.`);
      }
      if (months.some((p) => p.paidCents > 0 || p.amountCents !== p.baseAmountCents)) {
        throw conflict("package_not_applicable", "Il pacchetto si applica solo a mesi senza pagamenti né riduzioni.");
      }
      const rate = await db
        .prepare("SELECT amount_cents FROM fee_rates WHERE category_id = ?1 AND year = ?2")
        .bind(pkg.id, months[0]!.year)
        .first<{ amount_cents: number }>();
      if (!rate) throw invalid(`Manca il prezzo del pacchetto ${pkg.name} per il ${months[0]!.year}.`);
      splitCents(rate.amount_cents, months.length).forEach((cents, i) => {
        const p = months[i]!;
        p.amountCents = cents;
        p.adjustmentReason = `Pacchetto ${pkg.name}`;
        adjusted.add(p);
      });
    }

    // 3. Ripartizione dell'importo.
    const total = planned.reduce((sum, p) => sum + Math.max(0, p.amountCents - p.paidCents), 0);
    if (body.amountCents > total) {
      throw conflict("amount_exceeds", `L'importo supera il totale delle voci scelte (${(total / 100).toFixed(2).replace(".", ",")} €).`);
    }
    const allocations = allocate(
      body.amountCents,
      planned.map((p, i) => ({ id: i, remainingCents: Math.max(0, p.amountCents - p.paidCents) })),
    );

    // 4. Scrittura in un'unica transazione. L'id del pagamento è assegnato qui per
    //    poterlo usare nelle ripartizioni; in caso di conflitto si chiede di riprovare.
    const next = await db.prepare("SELECT COALESCE(MAX(id), 0) + 1 AS id FROM payments").first<{ id: number }>();
    const paymentId = next!.id;
    const now = nowIso();
    const dueRef = (p: Planned) =>
      p.existing
        ? { sql: "?", params: [p.existing.id] }
        : {
            sql: "(SELECT id FROM dues WHERE member_id = ? AND kind = 'mensile' AND year = ? AND month = ? AND cancelled_at IS NULL)",
            params: [member.id, p.year, p.month],
          };
    const statements: D1PreparedStatement[] = [];
    for (const p of planned) {
      if (!p.existing) {
        statements.push(
          db
            .prepare(
              `INSERT INTO dues (member_id, kind, year, month, category_id, base_amount_cents, amount_cents, adjustment_reason, charged_on, created_at, created_by)
               VALUES (?, 'mensile', ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            )
            .bind(member.id, p.year, p.month, p.categoryId, p.baseAmountCents, p.amountCents, p.adjustmentReason, paidOn, now, me),
        );
      } else if (adjusted.has(p)) {
        statements.push(db.prepare("UPDATE dues SET amount_cents = ?, adjustment_reason = ? WHERE id = ?").bind(p.amountCents, p.adjustmentReason, p.existing.id));
      }
    }
    statements.push(
      db
        .prepare(
          "INSERT INTO payments (id, member_id, paid_on, amount_cents, method_id, note, recorded_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(paymentId, member.id, paidOn, body.amountCents, method.id, body.note || null, me, now),
    );
    for (const a of allocations) {
      const ref = dueRef(planned[a.dueId]!);
      statements.push(
        db.prepare(`INSERT INTO payment_allocations (payment_id, due_id, amount_cents) VALUES (?, ${ref.sql}, ?)`).bind(paymentId, ...ref.params, a.amountCents),
      );
    }
    statements.push(
      auditStatement(db, me, "create", "payment", paymentId, {
        memberId: member.id,
        amountCents: body.amountCents,
        method: body.method,
        items: planned.map((p) => p.label),
        package: body.packageCategoryId ?? null,
      }),
    );
    try {
      await db.batch(statements);
    } catch (e) {
      if (e instanceof Error && /UNIQUE|PRIMARY KEY/.test(e.message)) {
        throw conflict("concurrent_update", "Qualcun altro ha appena registrato un pagamento: riprova.");
      }
      throw e;
    }
    return c.json(await findPayment(db, paymentId), 201);
  })
  .openapi(voidRoute, async (c) => {
    const { id } = c.req.valid("param");
    const { reason } = c.req.valid("json");
    const db = c.env.DB;
    const me = c.get("user").id;
    const current = await findPayment(db, id);
    if (current.voided) throw conflict("already_voided", "Il pagamento è già annullato.");
    const statements = [
      db.prepare("UPDATE payments SET voided_at = ?1, voided_by = ?2, void_reason = ?3 WHERE id = ?4").bind(nowIso(), me, reason, id),
      auditStatement(db, me, "void", "payment", id, { memberId: current.memberId, amountCents: current.amountCents, reason }),
    ];
    // Vendita a non socio pagata: annullando il pagamento si annulla anche la vendita
    // (non resterebbe un debito di uno sconosciuto) e la merce torna in magazzino,
    // a meno che la vendita non abbia altri pagamenti validi.
    if (current.memberId === null) {
      const { results } = await db
        .prepare(
          `SELECT d.id, d.variant_id, d.quantity FROM payment_allocations a JOIN dues d ON d.id = a.due_id
            WHERE a.payment_id = ?1 AND d.member_id IS NULL AND d.cancelled_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM payment_allocations a2 JOIN payments p2 ON p2.id = a2.payment_id
                               WHERE a2.due_id = d.id AND a2.payment_id <> ?1 AND p2.voided_at IS NULL)`,
        )
        .bind(id)
        .all<{ id: number; variant_id: number | null; quantity: number }>();
      for (const d of results) {
        statements.push(
          db.prepare("UPDATE dues SET cancelled_at = ?1, cancelled_by = ?2, cancel_reason = ?3 WHERE id = ?4").bind(nowIso(), me, `Pagamento annullato: ${reason}`, d.id),
        );
        const restock = restockStatement(db, d, me, todayIso());
        if (restock) statements.push(restock);
      }
    }
    await db.batch(statements);
    return c.json(await findPayment(db, id), 200);
  })
  .openapi(methodsRoute, async (c) => {
    const { results } = await c.env.DB.prepare("SELECT code, label, active FROM payment_methods ORDER BY sort_order, id").all<{ code: string; label: string; active: number }>();
    return c.json({ items: results.map((r) => ({ code: r.code, label: r.label, active: r.active === 1 })) }, 200);
  })
  .openapi(createMethodRoute, async (c) => {
    const { label } = c.req.valid("json");
    const db = c.env.DB;
    const code = slug(label);
    const exists = await db.prepare("SELECT 1 FROM payment_methods WHERE code = ?1 OR label = ?2 COLLATE NOCASE").bind(code, label).first();
    if (exists) throw conflict("method_exists", "Esiste già un metodo con questo nome.");
    await db.batch([
      db
        .prepare("INSERT INTO payment_methods (code, label, sort_order) VALUES (?1, ?2, (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM payment_methods))")
        .bind(code, label),
      auditStatement(db, c.get("user").id, "create", "payment_method", null, { code, label }),
    ]);
    return c.json({ code, label, active: true }, 201);
  })
  .openapi(updateMethodRoute, async (c) => {
    const { code } = c.req.valid("param");
    const b = c.req.valid("json");
    const db = c.env.DB;
    const res = await db
      .prepare("UPDATE payment_methods SET label = COALESCE(?1, label), active = COALESCE(?2, active) WHERE code = ?3")
      .bind(b.label ?? null, b.active === undefined ? null : Number(b.active), code)
      .run();
    if (!res.meta.changes) throw notFound("Metodo di pagamento non trovato.");
    await auditStatement(db, c.get("user").id, "update", "payment_method", null, { code, ...b }).run();
    const row = await db.prepare("SELECT code, label, active FROM payment_methods WHERE code = ?1").bind(code).first<{ code: string; label: string; active: number }>();
    return c.json({ code: row!.code, label: row!.label, active: row!.active === 1 }, 200);
  });
