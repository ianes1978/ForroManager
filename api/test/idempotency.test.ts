import { env, exports } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import { BASE, api, loggedInUser } from "./helpers.ts";

let token: string;
let memberId: number;

function post(path: string, body: unknown, key?: string, auth = token) {
  return exports.default.fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${auth}`, "Content-Type": "application/json", ...(key ? { "Idempotency-Key": key } : {}) },
    body: JSON.stringify(body),
  });
}

beforeAll(async () => {
  token = (await loggedInUser()).token;
  await api("/fees/2060/3", { method: "PUT", token, body: { amountCents: 2500 } });
  memberId = ((await (await api("/members", { token, body: { firstName: "R", lastName: "T", joinedOn: "2059-01-01" } })).json()) as { id: number }).id;
});

let nextMonth = 1;
const payment = (month = nextMonth++) => ({ memberId, amountCents: 1000, method: "contanti", paidOn: "2060-01-05", items: [{ year: 2060, month }] });
const countPayments = async () =>
  (await env.DB.prepare("SELECT COUNT(*) AS n FROM payments WHERE member_id = ?1").bind(memberId).first<{ n: number }>())!.n;

describe("protezione dai doppi salvataggi", () => {
  it("la stessa chiave ripetuta non registra due volte e restituisce lo stesso pagamento", async () => {
    const before = await countPayments();
    const body = payment();
    const first = await post("/payments", body, "chiave-prova-0000000001");
    expect(first.status).toBe(201);
    const second = await post("/payments", body, "chiave-prova-0000000001");
    expect(second.status).toBe(201);
    expect(second.headers.get("Idempotent-Replayed")).toBe("true");
    expect(((await second.json()) as { id: number }).id).toBe(((await first.json()) as { id: number }).id);
    expect(await countPayments()).toBe(before + 1);
  });

  it("chiavi diverse registrano operazioni diverse", async () => {
    const before = await countPayments();
    await post("/payments", payment(), "chiave-prova-0000000002");
    await post("/payments", payment(), "chiave-prova-0000000003");
    expect(await countPayments()).toBe(before + 2);
  });

  it("se l'operazione fallisce la chiave si libera e si può riprovare", async () => {
    const body = payment();
    const bad = await post("/payments", { ...body, method: "inesistente" }, "chiave-prova-0000000004");
    expect(bad.status).toBe(422);
    const good = await post("/payments", body, "chiave-prova-0000000004");
    expect(good.status).toBe(201);
    expect(good.headers.get("Idempotent-Replayed")).toBeNull();
  });

  it("una chiave non vale per un altro utente o un'altra operazione", async () => {
    await post("/payments", payment(), "chiave-prova-0000000005");
    const other = await loggedInUser();
    expect((await post("/payments", payment(), "chiave-prova-0000000005", other.token)).status).toBe(422);
    const product = (await (await api("/products", { token, body: { name: "Spilla", type: "altro", priceCents: 200 } })).json()) as { id: number };
    expect((await post("/sales", { productId: product.id, payment: { method: "contanti" } }, "chiave-prova-0000000005")).status).toBe(422);
  });

  it("funziona anche per vendite a non soci e addebiti", async () => {
    const product = (await (await api("/products", { token, body: { name: "Gadget", type: "altro", priceCents: 500 } })).json()) as { id: number };
    const a = await post("/sales", { productId: product.id, payment: { method: "contanti" } }, "chiave-vendita-00000001");
    const b = await post("/sales", { productId: product.id, payment: { method: "contanti" } }, "chiave-vendita-00000001");
    expect(((await b.json()) as { id: number }).id).toBe(((await a.json()) as { id: number }).id);
    const c1 = await post(`/members/${memberId}/charges`, { productId: product.id }, "chiave-addebito-0000001");
    const c2 = await post(`/members/${memberId}/charges`, { productId: product.id }, "chiave-addebito-0000001");
    expect(((await c2.json()) as { id: number }).id).toBe(((await c1.json()) as { id: number }).id);
  });

  it("rifiuta chiavi malformate", async () => {
    expect((await post("/payments", payment(), "corta")).status).toBe(400);
  });
});
