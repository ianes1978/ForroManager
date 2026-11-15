import { z } from "@hono/zod-openapi";
import { dueLabel, type DueKind } from "../domain/dues.ts";
import { ApiError, notFound } from "../lib/errors.ts";
import { PERIOD_LABEL_SQL, VARIANT_LABEL_SQL } from "./dues.ts";

/**
 * "Dove è usato": prima di eliminare un dato si controlla cosa lo riferisce.
 * Gli usi "bloccanti" (pagamenti, iscritti, soci con quella tariffa...) impediscono
 * l'eliminazione; gli altri vengono eliminati insieme e sono elencati nell'avviso.
 */

export const USAGE_KINDS = ["member", "product", "variant", "fee-category", "payment-method", "form", "course", "course-period", "due"] as const;
export type UsageKind = (typeof USAGE_KINDS)[number];

export const UseSchema = z.object({
  what: z.string().openapi({ example: "iscritti" }),
  count: z.number().int(),
  blocking: z.boolean().openapi({ description: "Se vero impedisce l'eliminazione; altrimenti viene eliminato insieme" }),
  examples: z.array(z.string()).openapi({ description: "Fino a 3 esempi (es. nomi dei soci)" }),
});

export const UsageSchema = z
  .object({
    name: z.string(),
    deletable: z.boolean(),
    uses: z.array(UseSchema),
    message: z.string().openapi({ description: "Avviso pronto da mostrare" }),
    hint: z.string().nullable().openapi({ description: "Alternativa all'eliminazione (es. disattivare)" }),
  })
  .openapi("Usage");

export type Use = z.infer<typeof UseSchema>;
export type Usage = z.infer<typeof UsageSchema>;

const MEMBER_NAME = "(m.last_name || ' ' || m.first_name)";
const MESI = ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"];
const euro = (cents: number) => `${(cents / 100).toFixed(2).replace(".", ",")} €`;
const shortDate = (iso: string) => `${Number(iso.slice(8, 10))} ${MESI[Number(iso.slice(5, 7)) - 1]} ${iso.slice(0, 4)}`;

function describe(u: Use): string {
  const extra = u.count - u.examples.length;
  const ex = u.examples.length ? ` (${u.examples.join(", ")}${extra > 0 ? ` e ${extra === 1 ? "un altro" : `altri ${extra}`}` : ""})` : "";
  return `${u.count} ${u.what}${ex}`;
}

/** Forme al singolare, per "1 pagamento" invece di "1 pagamenti". */
const SINGULAR: Record<string, string> = {
  "partecipanti o acquisti": "partecipante o acquisto",
  "pagamenti ricevuti (anche annullati)": "pagamento ricevuto (anche annullato)",
  "quote annullate mai pagate": "quota annullata mai pagata",
  "pagamenti": "pagamento",
  "quote e addebiti non pagati": "quota o addebito non pagato",
  "moduli consegnati": "modulo consegnato",
  "sospensioni": "sospensione",
  "carichi e rettifiche di magazzino": "carico o rettifica di magazzino",
  "varianti (taglie e colori)": "variante (taglia e colore)",
  "acquisti": "acquisto",
  "soci con questa tariffa": "socio con questa tariffa",
  "quote": "quota",
  "importi annuali": "importo annuale",
  "moduli restituiti firmati": "modulo restituito firmato",
  "consegne non ancora restituite": "consegna non ancora restituita",
  "iscritti": "iscritto",
  "periodi": "periodo",
  "pagamenti (anche annullati)": "pagamento (anche annullato)",
  "movimenti di magazzino (la merce torna disponibile)": "movimento di magazzino (la merce torna disponibile)",
};

function build(name: string, all: Use[], hint: string | null): Usage {
  const uses = all.filter((u) => u.count > 0).map((u) => (u.count === 1 && SINGULAR[u.what] ? { ...u, what: SINGULAR[u.what]! } : u));
  const blocking = uses.filter((u) => u.blocking);
  const along = uses.filter((u) => !u.blocking);
  let message: string;
  if (blocking.length) {
    message = `${name} è in uso: ${blocking.map(describe).join("; ")}. Non si può eliminare.${hint ? ` ${hint}` : ""}`;
  } else if (along.length) {
    message = `Verranno eliminati anche: ${along.map(describe).join("; ")}.`;
  } else {
    message = "Non è usato da nessuna parte.";
  }
  return { name, deletable: blocking.length === 0, uses, message, hint };
}

const count = async (db: D1Database, sql: string, ...params: unknown[]) =>
  (await db.prepare(sql).bind(...params).first<{ n: number }>())?.n ?? 0;
const names = async (db: D1Database, sql: string, ...params: unknown[]) =>
  (await db.prepare(`${sql} LIMIT 3`).bind(...params).all<{ x: string }>()).results.map((r) => r.x);

/** Quote (non annullate) che rientrano in un filtro: "iscritti", "acquisti"... con i nomi. */
async function dueUses(db: D1Database, where: string, id: unknown, what: string): Promise<Use[]> {
  const from = `FROM dues d LEFT JOIN members m ON m.id = d.member_id WHERE ${where}`;
  return [
    {
      what,
      blocking: true,
      count: await count(db, `SELECT COUNT(*) AS n ${from} AND d.cancelled_at IS NULL`, id),
      examples: await names(db, `SELECT COALESCE(${MEMBER_NAME}, 'non socio') AS x ${from} AND d.cancelled_at IS NULL ORDER BY d.id`, id),
    },
    {
      what: "pagamenti ricevuti (anche annullati)",
      blocking: true,
      count: await count(db, `SELECT COUNT(DISTINCT a.payment_id) AS n FROM payment_allocations a JOIN dues d ON d.id = a.due_id WHERE ${where}`, id),
      examples: [],
    },
    {
      what: "quote annullate mai pagate",
      blocking: false,
      count: await count(
        db,
        `SELECT COUNT(*) AS n ${from} AND d.cancelled_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM payment_allocations a WHERE a.due_id = d.id)`,
        id,
      ),
      examples: [],
    },
  ];
}

async function nameOf(db: D1Database, sql: string, id: unknown, what: string): Promise<string> {
  const row = await db.prepare(sql).bind(id).first<{ x: string }>();
  if (!row) throw notFound(`${what} non trovato.`);
  return row.x;
}

export async function usageOf(db: D1Database, kind: UsageKind, rawId: string): Promise<Usage> {
  const id = kind === "payment-method" ? rawId : Number(rawId);
  if (typeof id === "number" && !(Number.isInteger(id) && id > 0)) throw notFound("Elemento non trovato.");
  switch (kind) {
    case "member": {
      const name = await nameOf(db, `SELECT ${MEMBER_NAME} AS x FROM members m WHERE m.id = ?1`, id, "Socio");
      const pays = await db
        .prepare("SELECT paid_on, amount_cents, voided_at FROM payments WHERE member_id = ?1 ORDER BY paid_on DESC LIMIT 3")
        .bind(id)
        .all<{ paid_on: string; amount_cents: number; voided_at: string | null }>();
      const dues = await db
        .prepare(
          `SELECT d.kind, d.year, d.month, p.name AS product_name, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity, ${PERIOD_LABEL_SQL} AS period_label
             FROM dues d LEFT JOIN products p ON p.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id
             LEFT JOIN course_periods cp ON cp.id = d.course_period_id LEFT JOIN courses co ON co.id = cp.course_id
            WHERE d.member_id = ?1 AND d.cancelled_at IS NULL ORDER BY d.year, d.month LIMIT 3`,
        )
        .bind(id)
        .all<{ kind: DueKind; year: number; month: number | null; product_name: string | null; variant_label: string | null; quantity: number; period_label: string | null }>();
      return build(
        name,
        [
          {
            what: "pagamenti",
            blocking: true,
            count: await count(db, "SELECT COUNT(*) AS n FROM payments WHERE member_id = ?1", id),
            examples: pays.results.map((p) => `${shortDate(p.paid_on)} ${euro(p.amount_cents)}${p.voided_at ? " annullato" : ""}`),
          },
          {
            what: "quote e addebiti non pagati",
            blocking: false,
            count: await count(db, "SELECT COUNT(*) AS n FROM dues WHERE member_id = ?1", id),
            examples: dues.results.map((d) =>
              dueLabel({ kind: d.kind, year: d.year, month: d.month, productName: d.product_name, variantLabel: d.variant_label, quantity: d.quantity, periodLabel: d.period_label }),
            ),
          },
          { what: "moduli consegnati", blocking: false, count: await count(db, "SELECT COUNT(*) AS n FROM member_forms WHERE member_id = ?1", id), examples: [] },
          { what: "sospensioni", blocking: false, count: await count(db, "SELECT COUNT(*) AS n FROM member_suspensions WHERE member_id = ?1", id), examples: [] },
        ],
        "Se ha smesso di frequentare, segnalo come cessato: resta nello storico ma non riceve più quote.",
      );
    }
    case "product": {
      const name = await nameOf(db, "SELECT name AS x FROM products WHERE id = ?1", id, "Prodotto");
      return build(
        name,
        [
          ...(await dueUses(db, "d.product_id = ?1", id, "partecipanti o acquisti")),
          {
            what: "carichi e rettifiche di magazzino",
            blocking: false,
            count: await count(
              db,
              "SELECT COUNT(*) AS n FROM stock_movements s JOIN product_variants v ON v.id = s.variant_id WHERE v.product_id = ?1 AND s.kind IN ('carico', 'rettifica')",
              id,
            ),
            examples: [],
          },
          {
            what: "varianti (taglie e colori)",
            blocking: false,
            count: await count(db, "SELECT COUNT(*) AS n FROM product_variants WHERE product_id = ?1 AND (size <> '' OR color <> '')", id),
            examples: await names(db, `SELECT ${VARIANT_LABEL_SQL} AS x FROM product_variants v WHERE v.product_id = ?1 AND (v.size <> '' OR v.color <> '') ORDER BY v.id`, id),
          },
        ],
        "Puoi disattivarlo: non comparirà più tra i prodotti in vendita.",
      );
    }
    case "variant": {
      const row = await db
        .prepare(`SELECT p.name || COALESCE(' (' || ${VARIANT_LABEL_SQL} || ')', '') AS x, v.product_id FROM product_variants v JOIN products p ON p.id = v.product_id WHERE v.id = ?1`)
        .bind(id)
        .first<{ x: string; product_id: number }>();
      if (!row) throw notFound("Variante non trovata.");
      const others = await count(db, "SELECT COUNT(*) AS n FROM product_variants WHERE product_id = ?1 AND id <> ?2", row.product_id, id);
      return build(
        row.x,
        [
          ...(others === 0 ? [{ what: "è l'unica variante del prodotto (elimina il prodotto)", blocking: true, count: 1, examples: [] }] : []),
          ...(await dueUses(db, "d.variant_id = ?1", id, "acquisti")),
          {
            what: "carichi e rettifiche di magazzino",
            blocking: false,
            count: await count(db, "SELECT COUNT(*) AS n FROM stock_movements WHERE variant_id = ?1 AND kind IN ('carico', 'rettifica')", id),
            examples: [],
          },
        ],
        "Puoi disattivarla: non comparirà più nelle vendite.",
      );
    }
    case "fee-category": {
      const cat = await db.prepare("SELECT name, kind, active FROM fee_categories WHERE id = ?1").bind(id).first<{ name: string; kind: string; active: number }>();
      if (!cat) throw notFound("Tariffa non trovata.");
      const label = { annuale: "Quota associativa", mensile: "Quota mensile", pacchetto: "Pacchetto" }[cat.kind] ?? "Tariffa";
      const lastActive =
        cat.kind !== "pacchetto" && cat.active === 1 && (await count(db, "SELECT COUNT(*) AS n FROM fee_categories WHERE kind = ?1 AND active = 1 AND id <> ?2", cat.kind, id)) === 0;
      return build(
        `${label} ${cat.name}`,
        [
          ...(lastActive ? [{ what: "è l'unica tariffa attiva di questo tipo", blocking: true, count: 1, examples: [] }] : []),
          {
            what: "soci con questa tariffa",
            blocking: true,
            count: await count(db, "SELECT COUNT(*) AS n FROM members WHERE annual_category_id = ?1 OR monthly_category_id = ?1", id),
            examples: await names(db, `SELECT ${MEMBER_NAME} AS x FROM members m WHERE m.annual_category_id = ?1 OR m.monthly_category_id = ?1 ORDER BY m.last_name`, id),
          },
          ...(await dueUses(db, "d.category_id = ?1", id, "quote")),
          { what: "importi annuali", blocking: false, count: await count(db, "SELECT COUNT(*) AS n FROM fee_rates WHERE category_id = ?1", id), examples: [] },
        ],
        "Puoi disattivarla: non sarà più proposta ai nuovi soci.",
      );
    }
    case "payment-method": {
      const m = await db.prepare("SELECT id, label, active FROM payment_methods WHERE code = ?1").bind(id).first<{ id: number; label: string; active: number }>();
      if (!m) throw notFound("Metodo di pagamento non trovato.");
      const lastActive = m.active === 1 && (await count(db, "SELECT COUNT(*) AS n FROM payment_methods WHERE active = 1 AND id <> ?1", m.id)) === 0;
      const pays = await db
        .prepare(`SELECT COALESCE(${MEMBER_NAME}, 'non socio') AS x FROM payments p LEFT JOIN members m ON m.id = p.member_id WHERE p.method_id = ?1 ORDER BY p.paid_on DESC LIMIT 3`)
        .bind(m.id)
        .all<{ x: string }>();
      return build(
        m.label,
        [
          ...(lastActive ? [{ what: "è l'unico metodo attivo", blocking: true, count: 1, examples: [] }] : []),
          { what: "pagamenti", blocking: true, count: await count(db, "SELECT COUNT(*) AS n FROM payments WHERE method_id = ?1", m.id), examples: pays.results.map((r) => r.x) },
        ],
        "Puoi disattivarlo: non sarà più proposto negli incassi.",
      );
    }
    case "form": {
      const name = await nameOf(db, "SELECT name AS x FROM forms WHERE id = ?1", id, "Modulo");
      const from = "FROM member_forms f JOIN members m ON m.id = f.member_id WHERE f.form_id = ?1";
      return build(
        name,
        [
          {
            what: "moduli restituiti firmati",
            blocking: true,
            count: await count(db, `SELECT COUNT(*) AS n ${from} AND f.returned_on IS NOT NULL`, id),
            examples: await names(db, `SELECT ${MEMBER_NAME} AS x ${from} AND f.returned_on IS NOT NULL ORDER BY m.last_name`, id),
          },
          { what: "consegne non ancora restituite", blocking: false, count: await count(db, `SELECT COUNT(*) AS n ${from} AND f.returned_on IS NULL`, id), examples: [] },
        ],
        "Puoi disattivarlo: non sarà più richiesto.",
      );
    }
    case "course":
    case "course-period": {
      const isCourse = kind === "course";
      const name = isCourse
        ? await nameOf(db, "SELECT name AS x FROM courses WHERE id = ?1", id, "Corso")
        : await nameOf(db, `SELECT ${PERIOD_LABEL_SQL} AS x FROM course_periods cp JOIN courses co ON co.id = cp.course_id WHERE cp.id = ?1`, id, "Periodo");
      const where = isCourse ? "d.course_period_id IN (SELECT id FROM course_periods WHERE course_id = ?1)" : "d.course_period_id = ?1";
      return build(
        name,
        [
          ...(await dueUses(db, `d.kind = 'periodo' AND ${where}`, id, "iscritti")),
          ...(isCourse ? [{ what: "periodi", blocking: false, count: await count(db, "SELECT COUNT(*) AS n FROM course_periods WHERE course_id = ?1", id), examples: [] }] : []),
        ],
        isCourse ? "Puoi disattivarlo per nasconderlo." : "Puoi chiuderlo alle iscrizioni.",
      );
    }
    case "due": {
      const d = await db
        .prepare(
          `SELECT d.kind, d.year, d.month, p.name AS product_name, ${VARIANT_LABEL_SQL} AS variant_label, d.quantity, ${PERIOD_LABEL_SQL} AS period_label
             FROM dues d LEFT JOIN products p ON p.id = d.product_id LEFT JOIN product_variants v ON v.id = d.variant_id
             LEFT JOIN course_periods cp ON cp.id = d.course_period_id LEFT JOIN courses co ON co.id = cp.course_id WHERE d.id = ?1`,
        )
        .bind(id)
        .first<{ kind: DueKind; year: number; month: number | null; product_name: string | null; variant_label: string | null; quantity: number; period_label: string | null }>();
      if (!d) throw notFound("Quota non trovata.");
      const pays = await db
        .prepare("SELECT p.paid_on, a.amount_cents, p.voided_at FROM payment_allocations a JOIN payments p ON p.id = a.payment_id WHERE a.due_id = ?1 ORDER BY p.paid_on LIMIT 3")
        .bind(id)
        .all<{ paid_on: string; amount_cents: number; voided_at: string | null }>();
      return build(
        dueLabel({ kind: d.kind, year: d.year, month: d.month, productName: d.product_name, variantLabel: d.variant_label, quantity: d.quantity, periodLabel: d.period_label }),
        [
          {
            what: "pagamenti (anche annullati)",
            blocking: true,
            count: await count(db, "SELECT COUNT(*) AS n FROM payment_allocations WHERE due_id = ?1", id),
            examples: pays.results.map((p) => `${shortDate(p.paid_on)} ${euro(p.amount_cents)}${p.voided_at ? " annullato" : ""}`),
          },
          {
            what: "movimenti di magazzino (la merce torna disponibile)",
            blocking: false,
            count: await count(db, "SELECT COUNT(*) AS n FROM stock_movements WHERE due_id = ?1", id),
            examples: [],
          },
        ],
        "Puoi annullarla indicando il motivo: resterà nello storico.",
      );
    }
  }
}

/** Errore 409 se il dato è usato; il messaggio dice dove. */
export async function assertDeletable(db: D1Database, kind: UsageKind, id: string | number, code: string): Promise<Usage> {
  const usage = await usageOf(db, kind, String(id));
  if (!usage.deletable) throw new ApiError(409, code, usage.message, { usage });
  return usage;
}
