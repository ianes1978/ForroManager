import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("GET /api/v1/health", () => {
  it("risponde ok quando il database è raggiungibile", async () => {
    const res = await exports.default.fetch("http://example.com/api/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok" });
  });

  it("risponde 404 in JSON per percorsi API sconosciuti", async () => {
    const res = await exports.default.fetch("http://example.com/api/v1/non-esiste");
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ error: { code: "not_found" } });
  });
});
