/**
 * Rigenera api/openapi.json dalla definizione delle rotte (stesso codice del Worker).
 *   npm run openapi
 * Un test verifica che il file nel repository sia allineato al codice.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import app from "../src/index.ts";

const res = await app.request("/api/v1/openapi.json", {}, { DEV_CORS_ORIGIN: "" });
const doc = (await res.json()) as { openapi?: string; paths?: object };
if (!res.ok || !doc.openapi || !doc.paths) {
  console.error("Generazione della specifica fallita:", JSON.stringify(doc));
  process.exit(1);
}
const text = `${JSON.stringify(doc, null, 2)}\n`;
writeFileSync(new URL("../openapi.json", import.meta.url), text);
console.error(`openapi.json aggiornato: ${Object.keys(doc.paths).length} percorsi`);

// Livello dell'API: aumenta di uno ogni volta che la specifica cambia. L'app ha
// lo stesso numero (app/lib/config/api_level.dart, verificato dai test) e così
// capisce se lei o il server sono rimasti indietro.
const levelFile = new URL("../src/api-level.ts", import.meta.url);
const current = readFileSync(levelFile, "utf8");
const level = Number(/API_LEVEL = (\d+)/.exec(current)?.[1] ?? "0");
const oldHash = /OPENAPI_SHA256 = "([0-9a-f]*)"/.exec(current)?.[1] ?? "";
const hash = createHash("sha256").update(text).digest("hex");
if (hash !== oldHash) {
  const next = level + 1;
  writeFileSync(
    levelFile,
    `// Generato da \`npm run openapi\`: non modificare a mano.\n` +
      `// Il livello aumenta quando cambia openapi.json; l'app deve avere lo stesso numero.\n` +
      `export const API_LEVEL = ${next};\n` +
      `export const OPENAPI_SHA256 = "${hash}";\n`,
  );
  console.error(`Livello API: ${level} → ${next}. Aggiorna anche app/lib/config/api_level.dart (kApiLevel = ${next}).`);
}
