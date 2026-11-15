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

describe("eliminazione utenti", () => {
  it("elimina un altro utente: sparisce dall'elenco, non accede più e l'email torna libera", async () => {
    const me = await loggedInUser();
    const other = await loggedInUser({ name: "Provvisorio" });
    const res = await api(`/users/${other.id}`, { method: "DELETE", token: me.token });
    expect(res.status).toBe(204);
    const list = (await (await api("/users", { token: me.token })).json()) as { items: { id: number }[] };
    expect(list.items.some((u) => u.id === other.id)).toBe(false);
    expect((await api("/auth/me", { token: other.token })).status).toBe(401);
    await expect(login(other.email)).rejects.toThrow(/401/);
    const again = await api("/users", { token: me.token, body: { email: other.email, name: "Nuovo", temporaryPassword: "temporanea-lunga-1" } });
    expect(again.status).toBe(201);
    expect((await api(`/users/${other.id}`, { method: "DELETE", token: me.token })).status).toBe(404);
    const audit = (await (await api("/audit?entity=user", { token: me.token })).json()) as { items: { description: string }[] };
    expect(audit.items.some((a) => a.description === "ha eliminato un utente")).toBe(true);
  });

  it("non permette di eliminare se stessi", async () => {
    const me = await loggedInUser();
    const res = await api(`/users/${me.id}`, { method: "DELETE", token: me.token });
    expect(res.status).toBe(409);
    expect(await errorCode(res)).toBe("cannot_delete_self");
  });

  it("lo storico conserva il nome di chi ha registrato i pagamenti", async () => {
    const me = await loggedInUser();
    const cassiere = await loggedInUser({ name: "Cassiere Provvisorio" });
    const m = (await (await api("/members", { token: cassiere.token, body: { firstName: "A", lastName: "B", joinedOn: "2026-01-01" } })).json()) as { id: number };
    const p = (await (await api("/products", { token: cassiere.token, body: { name: "Spilla", type: "altro", priceCents: 100 } })).json()) as { id: number };
    const due = (await (await api(`/members/${m.id}/charges`, { token: cassiere.token, body: { productId: p.id } })).json()) as { id: number };
    const pay = (await (await api("/payments", { token: cassiere.token, body: { memberId: m.id, amountCents: 100, method: "contanti", items: [{ dueId: due.id }] } })).json()) as { id: number };
    await api(`/users/${cassiere.id}`, { method: "DELETE", token: me.token });
    const detail = (await (await api(`/payments/${pay.id}`, { token: me.token })).json()) as { recordedBy: { name: string } };
    expect(detail.recordedBy.name).toBe("Cassiere Provvisorio");
  });
});
