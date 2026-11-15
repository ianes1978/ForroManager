import { Hono } from "hono";

const app = new Hono<{ Bindings: Env }>().basePath("/api/v1");

// Stato del servizio: non tocca dati personali.
app.get("/health", async (c) => {
  const row = await c.env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
  return c.json({ status: row?.ok === 1 ? "ok" : "degraded" });
});

app.notFound((c) => c.json({ error: { code: "not_found", message: "Risorsa non trovata." } }, 404));

export default app;
