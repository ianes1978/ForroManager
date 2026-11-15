/**
 * Crea il SQL per inserire un utente (serve per il primo accesso: non esiste
 * registrazione libera). Eseguilo con Node 22 o successivo:
 *
 *   node scripts/create-user.ts --email roberta@esempio.it --name "Roberta" > .user.sql
 *   npx wrangler d1 execute forromanager-db --local --file .user.sql
 *   rm .user.sql
 *
 * Il pepe è letto da PASSWORD_PEPPER o, in sua assenza, da .dev.vars.
 * Per il database remoto usa lo stesso valore del secret di produzione.
 * La password temporanea viene stampata sul terminale (stderr) e va cambiata
 * al primo accesso.
 */
import { existsSync, readFileSync } from "node:fs";
import { hashPassword, randomBytes, toBase64Url } from "../src/lib/crypto.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function pepper(): string {
  if (process.env.PASSWORD_PEPPER) return process.env.PASSWORD_PEPPER;
  if (existsSync(".dev.vars")) {
    const m = /^PASSWORD_PEPPER=(.+)$/m.exec(readFileSync(".dev.vars", "utf8"));
    if (m) return m[1]!.trim();
  }
  throw new Error("Imposta PASSWORD_PEPPER (o crea .dev.vars).");
}

const sql = (s: string) => `'${s.replace(/'/g, "''")}'`;

const email = arg("email")?.trim().toLowerCase();
const name = arg("name")?.trim();
if (!email || !name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
  console.error('Uso: node scripts/create-user.ts --email nome@esempio.it --name "Nome"');
  process.exit(1);
}

const password = toBase64Url(randomBytes(12)); // 16 caratteri casuali
const h = await hashPassword(password, pepper());
const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

process.stdout.write(
  `INSERT INTO users (email, name, password_hash, password_salt, password_iterations, must_change_password, active, created_at, updated_at)\n` +
    `VALUES (${sql(email)}, ${sql(name)}, ${sql(h.hash)}, ${sql(h.salt)}, ${h.iterations}, 1, 1, ${sql(now)}, ${sql(now)});\n`,
);
console.error(`Password temporanea per ${email}: ${password}\n(da cambiare al primo accesso)`);
