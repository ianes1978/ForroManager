import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import committed from "../openapi.json";
import { API_LEVEL, OPENAPI_SHA256 } from "../src/api-level.ts";

describe("specifica OpenAPI", () => {
  it("il file openapi.json nel repository è allineato al codice (rigenera con: npm run openapi)", async () => {
    const res = await exports.default.fetch("http://localhost/api/v1/openapi.json");
    expect(await res.json()).toEqual(committed);
  });

  it("documenta l'autenticazione Bearer sulle rotte protette", async () => {
    const doc = committed as unknown as { paths: Record<string, Record<string, { security?: unknown[] }>> };
    expect(doc.paths["/api/v1/members"]!.get!.security).toEqual([{ Bearer: [] }]);
    expect(doc.paths["/api/v1/auth/login"]!.post!.security).toBeUndefined();
  });

  it("il livello dell'API corrisponde alla specifica salvata (rigenera con: npm run openapi)", async () => {
    const text = `${JSON.stringify(committed, null, 2)}\n`;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    expect(hex).toBe(OPENAPI_SHA256);
    expect(API_LEVEL).toBeGreaterThan(0);
  });

  it("indica il livello dell'API su ogni risposta e su /version", async () => {
    const res = await exports.default.fetch("http://localhost/api/v1/health");
    expect(res.headers.get("X-Api-Level")).toBe(String(API_LEVEL));
    const unauth = await exports.default.fetch("http://localhost/api/v1/members");
    expect(unauth.status).toBe(401);
    expect(unauth.headers.get("X-Api-Level")).toBe(String(API_LEVEL));
    const v = (await (await exports.default.fetch("http://localhost/api/v1/version")).json()) as { apiLevel: number; appDownloadUrl: string };
    expect(v.apiLevel).toBe(API_LEVEL);
    expect(v.appDownloadUrl).toMatch(/^https:\/\//);
  });
});
