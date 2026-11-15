/**
 * Rigenera api/openapi.json dalla definizione delle rotte (stesso codice del Worker).
 *   npm run openapi
 * Un test verifica che il file nel repository sia allineato al codice.
 */
import { writeFileSync } from "node:fs";
import app from "../src/index.ts";

const res = await app.request("/api/v1/openapi.json", {}, { DEV_CORS_ORIGIN: "" });
const doc = (await res.json()) as { openapi?: string; paths?: object };
if (!res.ok || !doc.openapi || !doc.paths) {
  console.error("Generazione della specifica fallita:", JSON.stringify(doc));
  process.exit(1);
}
writeFileSync(new URL("../openapi.json", import.meta.url), `${JSON.stringify(doc, null, 2)}\n`);
console.error(`openapi.json aggiornato: ${Object.keys(doc.paths).length} percorsi`);
