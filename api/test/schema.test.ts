import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";

const T = "2026-11-15T10:00:00Z";

async function seed() {
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO users (id, email, name, password_hash, password_salt, password_iterations, created_at, updated_at)
       VALUES (1, 'a@esempio.it', 'Utente', 'h', 's', 1, ?1, ?1)`,
    ).bind(T),
    env.DB.prepare(
      `INSERT INTO members (id, first_name, last_name, joined_on, annual_category_id, monthly_category_id,
                            created_at, created_by, updated_at, updated_by)
       VALUES (1, 'Mario', 'Rossi', '2026-01-10', 1, 3, ?1, 1, ?1, 1)`,
    ).bind(T),
  ]);
}

function insertDue(month: number | null, amount = 2500, base = 2500, reason: string | null = null) {
  return env.DB.prepare(
    `INSERT INTO dues (member_id, kind, year, month, category_id, base_amount_cents, amount_cents,
                       adjustment_reason, charged_on, created_at, created_by)
     VALUES (1, ?1, 2026, ?2, ?3, ?4, ?5, ?6, '2026-11-01', ?7, 1)`,
  )
    .bind(month === null ? "annuale" : "mensile", month, month === null ? 1 : 3, base, amount, reason, T)
    .run();
}

describe("schema del database", () => {
  beforeAll(seed);

  it("crea i metodi di pagamento e le categorie iniziali", async () => {
    const methods = await env.DB.prepare("SELECT code FROM payment_methods ORDER BY sort_order").all();
    expect(methods.results.map((r) => r.code)).toEqual(["contanti", "bonifico", "paypal", "altro"]);
  });

  it("impedisce due quote attive per lo stesso socio e periodo", async () => {
    await insertDue(5);
    await expect(insertDue(5)).rejects.toThrow(/UNIQUE/);
  });

  it("permette di rigenerare una quota se la precedente è annullata", async () => {
    await insertDue(6);
    await env.DB.prepare(
      "UPDATE dues SET cancelled_at = ?1, cancelled_by = 1, cancel_reason = 'errore' WHERE month = 6",
    )
      .bind(T)
      .run();
    await expect(insertDue(6)).resolves.toBeTruthy();
  });

  it("richiede un motivo quando l'importo differisce dalla tariffa", async () => {
    await expect(insertDue(7, 1250, 2500, null)).rejects.toThrow(/CHECK/);
    await expect(insertDue(8, 1250, 2500, "Iscrizione a metà mese")).resolves.toBeTruthy();
  });

  it("rifiuta importi negativi e pagamenti a zero", async () => {
    await expect(insertDue(9, -1, -1)).rejects.toThrow(/CHECK/);
    await expect(
      env.DB.prepare(
        `INSERT INTO payments (member_id, paid_on, amount_cents, method_id, recorded_by, created_at)
         VALUES (1, '2026-11-15', 0, 1, 1, ?1)`,
      )
        .bind(T)
        .run(),
    ).rejects.toThrow(/CHECK/);
  });

  it("impone le chiavi esterne", async () => {
    await expect(
      env.DB.prepare(
        `INSERT INTO payments (member_id, paid_on, amount_cents, method_id, recorded_by, created_at)
         VALUES (999, '2026-11-15', 100, 1, 1, ?1)`,
      )
        .bind(T)
        .run(),
    ).rejects.toThrow(/FOREIGN KEY/);
  });
});
