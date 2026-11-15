import { HTTPException } from "hono/http-exception";
import { cors } from "hono/cors";
import { ApiError } from "./lib/errors.ts";
import { createRouter } from "./lib/http.ts";
import { authRoutes } from "./routes/auth.ts";
import { dueRoutes } from "./routes/dues.ts";
import { feeRoutes } from "./routes/fees.ts";
import { memberRoutes } from "./routes/members.ts";
import { paymentRoutes } from "./routes/payments.ts";
import { productRoutes } from "./routes/products.ts";
import { userRoutes } from "./routes/users.ts";

const API_VERSION = "1.0.0";

const app = createRouter().basePath("/api/v1");

// CORS solo in sviluppo, per il server locale di Flutter web.
app.use("*", async (c, next) => {
  const origin = c.env.DEV_CORS_ORIGIN;
  if (!origin) return next();
  return cors({ origin, allowHeaders: ["Authorization", "Content-Type"], maxAge: 600 })(c, next);
});

app.openAPIRegistry.registerComponent("securitySchemes", "Bearer", { type: "http", scheme: "bearer" });

app.get("/health", async (c) => {
  const row = await c.env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
  return c.json({ status: row?.ok === 1 ? "ok" : "degraded" });
});

app.route("/", authRoutes);
app.route("/", userRoutes);
app.route("/", feeRoutes);
app.route("/", memberRoutes);
app.route("/", productRoutes);
app.route("/", dueRoutes);
app.route("/", paymentRoutes);

app.doc31("/openapi.json", {
  openapi: "3.1.0",
  info: { title: "ForroManager API", version: API_VERSION, description: "API del registro pagamenti dell'associazione." },
});

app.notFound((c) => c.json({ error: { code: "not_found", message: "Risorsa non trovata." } }, 404));

app.onError((err, c) => {
  if (err instanceof ApiError) {
    return c.json({ error: { code: err.code, message: err.message, details: err.details } }, err.status);
  }
  if (err instanceof HTTPException && err.status < 500) {
    return c.json({ error: { code: "bad_request", message: "Richiesta non valida." } }, err.status);
  }
  // Nei log solo informazioni tecniche: nessun dato personale (niente corpo della richiesta).
  console.error(JSON.stringify({ level: "error", path: c.req.path, method: c.req.method, error: err.name, message: err.message }));
  return c.json({ error: { code: "server_error", message: "Errore del server. Riprova tra qualche minuto." } }, 500);
});

export default app;
