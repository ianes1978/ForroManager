import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { PASSWORD_ITERATIONS } from "../src/lib/crypto.ts";
import { MAX_FAILED_LOGINS } from "../src/routes/auth.ts";
import { api, createUser, errorCode, login, loggedInUser } from "./helpers.ts";

describe("login", () => {
  it("accede con email in qualsiasi maiuscolo e restituisce token e scadenza", async () => {
    const u = await createUser();
    const res = await api("/auth/login", { body: { email: u.email.toUpperCase(), password: u.password } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { token: string; expiresAt: string; user: { email: string } };
    expect(body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.user.email).toBe(u.email);
    expect(Date.parse(body.expiresAt)).toBeGreaterThan(Date.now() + 29 * 86400_000);
  });

  it("salva solo l'hash del token, mai il token in chiaro", async () => {
    const u = await createUser();
    const token = await login(u.email);
    const found = await env.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE token_hash = ?1").bind(token).first<{ n: number }>();
    expect(found!.n).toBe(0);
  });

  it("risponde allo stesso modo per password errata ed email inesistente", async () => {
    const u = await createUser();
    const wrong = await api("/auth/login", { body: { email: u.email, password: "sbagliata-sbagliata" } });
    const missing = await api("/auth/login", { body: { email: "nessuno@esempio.it", password: "qualcosa-di-lungo" } });
    expect(wrong.status).toBe(401);
    expect(missing.status).toBe(401);
    expect(await errorCode(wrong)).toBe("invalid_credentials");
    expect(await errorCode(missing)).toBe("invalid_credentials");
  });

  it("blocca l'email dopo troppi tentativi falliti, anche con la password giusta", async () => {
    const u = await createUser();
    for (let i = 0; i < MAX_FAILED_LOGINS; i++) {
      await api("/auth/login", { body: { email: u.email, password: "sbagliata-sbagliata" } });
    }
    const res = await api("/auth/login", { body: { email: u.email, password: u.password } });
    expect(res.status).toBe(429);
    expect(await errorCode(res)).toBe("too_many_attempts");
  });

  it("azzera il conteggio degli errori dopo un accesso riuscito", async () => {
    const u = await createUser();
    for (let i = 0; i < MAX_FAILED_LOGINS - 1; i++) {
      await api("/auth/login", { body: { email: u.email, password: "sbagliata-sbagliata" } });
    }
    await login(u.email);
    for (let i = 0; i < MAX_FAILED_LOGINS - 1; i++) {
      await api("/auth/login", { body: { email: u.email, password: "sbagliata-sbagliata" } });
    }
    await expect(login(u.email)).resolves.toBeTruthy();
  });

  it("non salva l'email in chiaro tra i tentativi", async () => {
    const u = await createUser();
    await api("/auth/login", { body: { email: u.email, password: "sbagliata-sbagliata" } });
    const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM login_attempts WHERE email_hash = ?1").bind(u.email).first<{ n: number }>();
    expect(row!.n).toBe(0);
  });

  it("rifiuta gli utenti disattivati", async () => {
    const u = await createUser({ active: false });
    const res = await api("/auth/login", { body: { email: u.email, password: u.password } });
    expect(res.status).toBe(401);
  });

  it("aggiorna l'hash se le iterazioni configurate sono aumentate", async () => {
    const u = await createUser({ iterations: 1000 });
    await login(u.email);
    const row = await env.DB.prepare("SELECT password_iterations AS it FROM users WHERE id = ?1").bind(u.id).first<{ it: number }>();
    expect(row!.it).toBe(PASSWORD_ITERATIONS);
    await expect(login(u.email)).resolves.toBeTruthy();
  });
});

describe("sessioni", () => {
  it("richiede un token per le rotte protette", async () => {
    expect((await api("/auth/me")).status).toBe(401);
    expect((await api("/auth/me", { token: "token-inventato-ma-abbastanza-lungo" })).status).toBe(401);
  });

  it("rifiuta una sessione scaduta", async () => {
    const u = await loggedInUser();
    await env.DB.prepare("UPDATE sessions SET expires_at = '2020-01-01T00:00:00Z' WHERE user_id = ?1").bind(u.id).run();
    const res = await api("/auth/me", { token: u.token });
    expect(res.status).toBe(401);
    expect(await errorCode(res)).toBe("unauthorized");
  });

  it("rinnova la scadenza quando la sessione viene usata", async () => {
    const u = await loggedInUser();
    await env.DB.prepare(
      "UPDATE sessions SET last_used_at = '2026-01-01T00:00:00Z', expires_at = ?2 WHERE user_id = ?1",
    )
      .bind(u.id, new Date(Date.now() + 86400_000).toISOString())
      .run();
    expect((await api("/auth/me", { token: u.token })).status).toBe(200);
    const s = await env.DB.prepare("SELECT expires_at FROM sessions WHERE user_id = ?1").bind(u.id).first<{ expires_at: string }>();
    expect(Date.parse(s!.expires_at)).toBeGreaterThan(Date.now() + 29 * 86400_000);
  });

  it("il logout revoca la sessione", async () => {
    const u = await loggedInUser();
    expect((await api("/auth/logout", { method: "POST", token: u.token })).status).toBe(204);
    expect((await api("/auth/me", { token: u.token })).status).toBe(401);
  });

  it("con password temporanea consente solo profilo, cambio password e uscita", async () => {
    const u = await loggedInUser({ mustChange: true });
    expect((await api("/auth/me", { token: u.token })).status).toBe(200);
    const res = await api("/users", { token: u.token });
    expect(res.status).toBe(403);
    expect(await errorCode(res)).toBe("password_change_required");
  });
});

describe("cambio password", () => {
  it("verifica la password attuale", async () => {
    const u = await loggedInUser();
    const res = await api("/auth/password", {
      token: u.token,
      body: { currentPassword: "non-e-questa-davvero", newPassword: "nuova-password-lunga" },
    });
    expect(res.status).toBe(401);
  });

  it("richiede almeno 12 caratteri", async () => {
    const u = await loggedInUser();
    const res = await api("/auth/password", { token: u.token, body: { currentPassword: u.password, newPassword: "corta" } });
    expect(res.status).toBe(422);
  });

  it("aggiorna la password, toglie l'obbligo di cambio e chiude le altre sessioni", async () => {
    const u = await loggedInUser({ mustChange: true });
    const other = await login(u.email);
    const res = await api("/auth/password", {
      token: u.token,
      body: { currentPassword: u.password, newPassword: "nuova-password-lunga" },
    });
    expect(res.status).toBe(204);
    expect((await api("/users", { token: u.token })).status).toBe(200);
    expect((await api("/auth/me", { token: other })).status).toBe(401);
    await expect(login(u.email, "nuova-password-lunga")).resolves.toBeTruthy();
    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM audit_log WHERE action = 'password_change' AND entity_id = ?1",
    )
      .bind(u.id)
      .first<{ n: number }>();
    expect(audit!.n).toBe(1);
  });
});
