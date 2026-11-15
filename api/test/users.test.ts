import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, createUser, errorCode, login, loggedInUser } from "./helpers.ts";

describe("gestione utenti", () => {
  it("elenca gli utenti senza esporre dati delle password", async () => {
    const me = await loggedInUser();
    const res = await api("/users", { token: me.token });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: Record<string, unknown>[] };
    expect(body.items.length).toBeGreaterThan(0);
    for (const u of body.items) {
      expect(Object.keys(u).sort()).toEqual(["active", "createdAt", "email", "id", "mustChangePassword", "name", "updatedAt"]);
    }
  });

  it("crea un utente con password temporanea da cambiare al primo accesso", async () => {
    const me = await loggedInUser();
    const res = await api("/users", {
      token: me.token,
      body: { email: "Nuovo.Utente@Esempio.it", name: "Nuovo", temporaryPassword: "temporanea-lunga-1" },
    });
    expect(res.status).toBe(201);
    const created = (await res.json()) as { email: string; mustChangePassword: boolean };
    expect(created).toMatchObject({ email: "nuovo.utente@esempio.it", mustChangePassword: true });
    const audit = await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE entity = 'user' AND action = 'create'").first<{ n: number }>();
    expect(audit!.n).toBeGreaterThan(0);
  });

  it("rifiuta email duplicate e dati non validi", async () => {
    const me = await loggedInUser();
    const dup = await api("/users", { token: me.token, body: { email: me.email, name: "X", temporaryPassword: "temporanea-lunga-1" } });
    expect(dup.status).toBe(409);
    expect(await errorCode(dup)).toBe("email_taken");
    const bad = await api("/users", { token: me.token, body: { email: "non-una-email", name: "", temporaryPassword: "corta" } });
    expect(bad.status).toBe(422);
    const details = ((await bad.json()) as { error: { details: { field: string }[] } }).error.details.map((d) => d.field);
    expect(details).toEqual(expect.arrayContaining(["email", "name", "temporaryPassword"]));
  });

  it("non permette di disattivare se stessi", async () => {
    const me = await loggedInUser();
    const res = await api(`/users/${me.id}`, { method: "PATCH", token: me.token, body: { active: false } });
    expect(res.status).toBe(409);
    expect(await errorCode(res)).toBe("cannot_deactivate_self");
  });

  it("disattivare un utente chiude le sue sessioni e gli impedisce di accedere", async () => {
    const me = await loggedInUser();
    const other = await loggedInUser();
    const res = await api(`/users/${other.id}`, { method: "PATCH", token: me.token, body: { active: false } });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { active: boolean }).active).toBe(false);
    expect((await api("/auth/me", { token: other.token })).status).toBe(401);
    await expect(login(other.email)).rejects.toThrow(/401/);
  });

  it("reimposta la password di un altro utente e chiude le sue sessioni", async () => {
    const me = await loggedInUser();
    const other = await loggedInUser();
    const res = await api(`/users/${other.id}/password`, { token: me.token, body: { temporaryPassword: "nuova-temporanea-1" } });
    expect(res.status).toBe(204);
    expect((await api("/auth/me", { token: other.token })).status).toBe(401);
    const t = await login(other.email, "nuova-temporanea-1");
    expect((await api("/users", { token: t })).status).toBe(403);
  });

  it("non reimposta la propria password da qui", async () => {
    const me = await loggedInUser();
    const res = await api(`/users/${me.id}/password`, { token: me.token, body: { temporaryPassword: "nuova-temporanea-1" } });
    expect(res.status).toBe(409);
  });

  it("chiude tutte le sessioni di un utente", async () => {
    const me = await loggedInUser();
    const other = await loggedInUser();
    const second = await login(other.email);
    expect((await api(`/users/${other.id}/revoke-sessions`, { method: "POST", token: me.token })).status).toBe(204);
    expect((await api("/auth/me", { token: other.token })).status).toBe(401);
    expect((await api("/auth/me", { token: second })).status).toBe(401);
  });

  it("risponde 404 per utenti inesistenti", async () => {
    const me = await loggedInUser();
    expect((await api("/users/99999", { method: "PATCH", token: me.token, body: { name: "X" } })).status).toBe(404);
  });

  it("modifica nome ed email", async () => {
    const me = await loggedInUser();
    const other = await createUser();
    const res = await api(`/users/${other.id}`, {
      method: "PATCH",
      token: me.token,
      body: { name: "Nome Nuovo", email: `nuova-${other.id}@esempio.it` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ name: "Nome Nuovo", email: `nuova-${other.id}@esempio.it` });
  });
});
