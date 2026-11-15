import { env, exports } from "cloudflare:workers";
import { hashPassword } from "../src/lib/crypto.ts";

export const BASE = "http://localhost/api/v1";
export const DEFAULT_PASSWORD = "password-di-prova-lunga";

let counter = 0;

/** Crea un utente direttamente nel database (password già cambiata, salvo indicazione). */
export async function createUser(
  opts: { email?: string; name?: string; password?: string; mustChange?: boolean; active?: boolean; iterations?: number } = {},
) {
  const email = opts.email ?? `utente${++counter}-${Date.now()}@esempio.it`;
  const h = await hashPassword(opts.password ?? DEFAULT_PASSWORD, env.PASSWORD_PEPPER, opts.iterations);
  const row = await env.DB.prepare(
    `INSERT INTO users (email, name, password_hash, password_salt, password_iterations, must_change_password, active, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z') RETURNING id`,
  )
    .bind(email, opts.name ?? "Utente di prova", h.hash, h.salt, h.iterations, opts.mustChange ? 1 : 0, opts.active === false ? 0 : 1)
    .first<{ id: number }>();
  return { id: row!.id, email, password: opts.password ?? DEFAULT_PASSWORD };
}

export function api(path: string, init: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {}) {
  const headers: Record<string, string> = { ...init.headers };
  if (init.token) headers.Authorization = `Bearer ${init.token}`;
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  return exports.default.fetch(`${BASE}${path}`, {
    method: init.method ?? (init.body !== undefined ? "POST" : "GET"),
    headers,
    body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
  });
}

export async function login(email: string, password: string = DEFAULT_PASSWORD): Promise<string> {
  const res = await api("/auth/login", { body: { email, password } });
  if (res.status !== 200) throw new Error(`login fallito: ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

/** Utente già autenticato, pronto per le chiamate. */
export async function loggedInUser(opts: Parameters<typeof createUser>[0] = {}) {
  const user = await createUser(opts);
  return { ...user, token: await login(user.email, user.password) };
}

export async function errorCode(res: Response): Promise<string> {
  return ((await res.json()) as { error: { code: string } }).error.code;
}
