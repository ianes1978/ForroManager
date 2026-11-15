import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Usage { name: string; deletable: boolean; message: string; uses: { what: string; count: number; blocking: boolean; examples: string[] }[] }

let token: string;
const usage = async (kind: string, id: number | string) => (await (await api(`/usage/${kind}/${id}`, { token })).json()) as Usage;
const del = (path: string) => api(path, { token, method: "DELETE" });
async function member(first: string, last = "Prova") {
  return ((await (await api("/members", { token, body: { firstName: first, lastName: last, joinedOn: "2026-01-01" } })).json()) as { id: number }).id;
}
async function product(name: string, variants?: { size: string; color: string }[]) {
  const res = await api("/products", { token, body: { name, type: variants ? "merchandising" : "stage", priceCents: 1500, tracksStock: !!variants, variants } });
  return (await res.json()) as { id: number; variants: { id: number }[] };
}

beforeAll(async () => {
  token = (await loggedInUser()).token;
});

describe("dove è usato ed eliminazione", () => {
  it("serve l'accesso", async () => {
    expect((await api("/usage/member/1")).status).toBe(401);
    expect((await api("/members/1", { method: "DELETE" })).status).toBe(401);
    expect((await api("/payment-methods/contanti", { method: "DELETE" })).status).toBe(401);
  });

  it("workshop: con partecipanti dice chi sono e non si elimina; senza si elimina", async () => {
    const w = await product("Workshop di prova");
    const a = await member("Anna", "Rossi");
    await api(`/members/${a}/charges`, { token, body: { productId: w.id } });
    const u = await usage("product", w.id);
    expect(u.deletable).toBe(false);
    expect(u.uses.find((x) => x.what === "partecipante o acquisto")).toMatchObject({ count: 1, examples: ["Rossi Anna"] });
    expect(u.message).toContain("1 partecipante o acquisto (Rossi Anna)");
    expect(await errorCode(await del(`/products/${w.id}`))).toBe("product_in_use");

    const vuoto = await product("Workshop creato per sbaglio");
    expect((await usage("product", vuoto.id)).deletable).toBe(true);
    expect((await del(`/products/${vuoto.id}`)).status).toBe(204);
    expect((await api(`/usage/product/${vuoto.id}`, { token })).status).toBe(404);
  });

  it("prodotto con varianti e carichi: avvisa cosa sparisce insieme", async () => {
    const p = await product("Felpa", [{ size: "S", color: "blu" }, { size: "M", color: "blu" }]);
    await api(`/variants/${p.variants[0]!.id}/stock`, { token, body: { kind: "carico", quantity: 5 } });
    const u = await usage("product", p.id);
    expect(u.deletable).toBe(true);
    expect(u.message).toContain("1 carico o rettifica di magazzino");
    expect(u.message).toContain("2 varianti (taglie e colori) (S · blu, M · blu)");
    // Una variante si elimina, l'ultima no.
    expect((await del(`/variants/${p.variants[1]!.id}`)).status).toBe(204);
    expect(await errorCode(await del(`/variants/${p.variants[0]!.id}`))).toBe("variant_in_use");
    expect((await del(`/products/${p.id}`)).status).toBe(204);
  });

  it("socio: senza pagamenti si elimina con quote e moduli, e il registro perde i suoi dati", async () => {
    const id = await member("Errato", "Inserito");
    await api(`/members/${id}`, { token, method: "PATCH", body: { notes: "telefono 333" } });
    const w = await product("Stage per socio");
    await api(`/members/${id}/charges`, { token, body: { productId: w.id } });
    const u = await usage("member", id);
    expect(u).toMatchObject({ name: "Inserito Errato", deletable: true });
    expect(u.message).toContain("quota o addebito non pagato");
    expect((await del(`/members/${id}`)).status).toBe(204);
    expect((await api(`/members/${id}`, { token })).status).toBe(404);
    const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE entity = 'member' AND entity_id = ?1 AND details LIKE '%333%'").bind(id).first<{ n: number }>();
    expect(left!.n).toBe(0);
    // Ora il workshop è libero.
    expect((await usage("product", w.id)).deletable).toBe(true);
  });

  it("socio con pagamenti: non si elimina e suggerisce di segnarlo cessato", async () => {
    const id = await member("Pagante");
    const w = await product("Stage pagato");
    const sale = (await (await api(`/members/${id}/charges`, { token, body: { productId: w.id } })).json()) as { id: number };
    await api("/payments", { token, body: { memberId: id, amountCents: 1500, method: "contanti", items: [{ dueId: sale.id }] } });
    const res = await del(`/members/${id}`);
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("member_in_use");
    expect(body.error.message).toContain("1 pagamento");
    expect(body.error.message).toContain("cessato");
  });

  it("tariffe, metodi e moduli", async () => {
    const cat = (await (await api("/fee-categories", { token, body: { kind: "mensile", name: "Prova eliminabile" } })).json()) as { id: number };
    expect((await del(`/fee-categories/${cat.id}`)).status).toBe(204);
    const someone = (await (await api(`/members/${await member("Con", "Tariffa")}`, { token })).json()) as { annualCategory: { id: number } };
    const used = await usage("fee-category", someone.annualCategory.id);
    expect(used.deletable).toBe(false);
    expect(used.message).toContain("soci con questa tariffa");

    await api("/payment-methods", { token, body: { label: "Satispay" } });
    expect((await usage("payment-method", "satispay")).deletable).toBe(true);
    expect((await del("/payment-methods/satispay")).status).toBe(204);

    const form = (await (await api("/forms", { token, body: { name: "Modulo di prova", required: false } })).json()) as { id: number };
    const m = await member("Firmataria", "Moduli");
    await api(`/forms/${form.id}/deliver-all`, { token, body: {} });
    expect((await usage("form", form.id)).deletable).toBe(true);
    const today = new Date().toISOString().slice(0, 10);
    expect((await api(`/members/${m}/forms/${form.id}`, { token, method: "PUT", body: { delivered: true, returnedOn: today } })).status).toBe(200);
    const u = await usage("form", form.id);
    expect(u.deletable).toBe(false);
    expect(u.uses[0]).toMatchObject({ what: "modulo restituito firmato", examples: ["Moduli Firmataria"] });
  });
});
