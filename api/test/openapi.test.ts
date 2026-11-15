import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import committed from "../openapi.json";

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
});
