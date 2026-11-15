import { beforeAll, describe, expect, it } from "vitest";
import { api, errorCode, loggedInUser } from "./helpers.ts";

let token: string;
const member = async (first: string) =>
  ((await (await api("/members", { token, body: { firstName: first, lastName: "Moduli", joinedOn: "2026-01-01" } })).json()) as { id: number }).id;
const bulk = (formId: number, action: string, memberIds: number[]) => api(`/forms/${formId}/members`, { token, body: { action, memberIds } });
const list = async (formId: number) =>
  ((await (await api(`/forms/${formId}/members`, { token })).json()) as { items: { memberId: number; returnedOn: string | null }[] }).items;

beforeAll(async () => {
  token = (await loggedInUser()).token;
});

describe("moduli: azioni su più soci", () => {
  it("consegna ad alcuni, segna firmati, rimette da riavere e ritira le consegne sbagliate", async () => {
    const form = (await (await api("/forms", { token, body: { name: "Liberatoria foto", required: false } })).json()) as { id: number };
    const [a, b, c] = [await member("Ada"), await member("Bea"), await member("Ciro")];

    expect(await (await bulk(form.id, "deliver", [a, b, a])).json()).toEqual({ changed: 2, skipped: 0 });
    expect(await (await bulk(form.id, "deliver", [a, c])).json()).toEqual({ changed: 1, skipped: 0 });
    expect((await list(form.id)).map((x) => x.memberId).sort()).toEqual([a, b, c].sort());

    expect(await (await bulk(form.id, "return", [a, b])).json()).toEqual({ changed: 2, skipped: 0 });
    expect(await (await bulk(form.id, "unreturn", [b])).json()).toEqual({ changed: 1, skipped: 0 });

    // A ha già firmato: non viene ritirato. B e C sì.
    expect(await (await bulk(form.id, "withdraw", [a, b, c])).json()).toEqual({ changed: 2, skipped: 1 });
    expect((await list(form.id)).map((x) => x.memberId)).toEqual([a]);
  });

  it("non consegna un modulo disattivato e richiede almeno un socio", async () => {
    const form = (await (await api("/forms", { token, body: { name: "Modulo spento", required: false } })).json()) as { id: number };
    await api(`/forms/${form.id}`, { token, method: "PATCH", body: { active: false } });
    expect(await errorCode(await bulk(form.id, "deliver", [await member("Dino")]))).toBe("form_inactive");
    expect((await bulk(form.id, "return", [])).status).toBe(422);
  });
});
