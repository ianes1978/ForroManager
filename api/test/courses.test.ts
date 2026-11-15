import { beforeAll, describe, expect, it } from "vitest";
import { todayIso } from "../src/lib/time.ts";
import { api, errorCode, loggedInUser } from "./helpers.ts";

interface Period { id: number; label: string; name: string; from: string; to: string; months: number; amountCents: number; enrolled: number; paid: number; updatedAt: string }
interface Course { id: number; name: string; periods: Period[] }
interface Due { id: number; kind: string; label: string; amountCents: number; status: string; coursePeriodId: number | null }

let token: string;
const Y = Number(todayIso().slice(0, 4));

async function member(name: string) {
  return ((await (await api("/members", { token, body: { firstName: name, lastName: "Corsista", joinedOn: `${Y - 1}-01-01` } })).json()) as { id: number }).id;
}
async function course(name: string): Promise<Course> {
  return (await (await api("/courses", { token, body: { name } })).json()) as Course;
}
async function period(courseId: number, from: string, to: string, amountCents: number): Promise<Period> {
  const res = await api(`/courses/${courseId}/periods`, { token, body: { from, to, amountCents } });
  if (res.status !== 201) throw new Error(await res.text());
  return (await res.json()) as Period;
}
async function dues(memberId: number, year = Y): Promise<{ items: Due[]; summary: { arrearsCents: number; inRegola: boolean } }> {
  return (await (await api(`/members/${memberId}/dues?year=${year}`, { token })).json()) as never;
}

beforeAll(async () => {
  token = (await loggedInUser()).token;
});

describe("corsi e periodi", () => {
  it("crea corsi e periodi di durata libera con nome automatico", async () => {
    const forro = await course("Forró");
    const q1 = await period(forro.id, `${Y}-01`, `${Y}-03`, 5000);
    expect(q1).toMatchObject({ name: "gen–mar " + Y, label: `Forró gen–mar ${Y}`, months: 3, amountCents: 5000, enrolled: 0 });
    const four = await period(forro.id, `${Y}-09`, `${Y}-12`, 12000);
    expect(four.months).toBe(4);
    const one = await period(forro.id, `${Y + 1}-01`, `${Y + 1}-01`, 4000);
    expect(one.name).toBe(`gennaio ${Y + 1}`);
    expect(await errorCode(await api(`/courses/${forro.id}/periods`, { token, body: { from: `${Y}-01`, to: `${Y}-03`, amountCents: 1 } }))).toBe("period_exists");
    expect((await api(`/courses/${forro.id}/periods`, { token, body: { from: `${Y}-05`, to: `${Y}-03`, amountCents: 1 } })).status).toBe(422);
    expect(await errorCode(await api("/courses", { token, body: { name: "forró" } }))).toBe("course_exists");
    const list = (await (await api(`/courses?year=${Y}`, { token })).json()) as { items: Course[] };
    expect(list.items.find((c) => c.id === forro.id)!.periods.map((p) => p.months)).toEqual([3, 4]);
  });

  it("iscrive i soci, conta gli arretrati del periodo iniziato e accetta il pagamento", async () => {
    const zouk = await course("Zouk");
    const p = await period(zouk.id, `${Y}-01`, `${Y}-03`, 6000);
    const a = await member("Anna");
    const b = await member("Bruno");
    const res = await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [a, b, a] } });
    expect(await res.json()).toEqual({ enrolled: 2, alreadyEnrolled: 0 });
    const again = await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [a] } });
    expect(await again.json()).toEqual({ enrolled: 0, alreadyEnrolled: 1 });

    const d = await dues(a);
    const due = d.items.find((x) => x.kind === "periodo")!;
    expect(due).toMatchObject({ label: `Zouk gen–mar ${Y}`, amountCents: 6000, status: "da_pagare", coursePeriodId: p.id });
    expect(d.summary).toMatchObject({ arrearsCents: 6000, inRegola: false });

    const pay = await api("/payments", { token, body: { memberId: a, amountCents: 6000, method: "bonifico", items: [{ dueId: due.id }] } });
    expect(((await pay.json()) as { description: string }).description).toBe(`Zouk gen–mar ${Y}`);
    expect((await dues(a)).summary.inRegola).toBe(true);

    const enr = (await (await api(`/course-periods/${p.id}/enrollments`, { token })).json()) as { period: Period; items: { memberId: number; paidCents: number }[] };
    expect(enr.period).toMatchObject({ enrolled: 2, paid: 1 });
    expect(enr.items.find((x) => x.memberId === a)!.paidCents).toBe(6000);
  });

  it("un periodo futuro non è un arretrato; un socio può seguire più corsi", async () => {
    const c1 = await course("Samba");
    const c2 = await course("Lambada");
    const future = await period(c1.id, `${Y + 1}-04`, `${Y + 1}-06`, 5000);
    const other = await period(c2.id, `${Y + 1}-04`, `${Y + 1}-06`, 3000);
    const m = await member("Carla");
    await api(`/course-periods/${future.id}/enroll`, { token, body: { memberIds: [m] } });
    await api(`/course-periods/${other.id}/enroll`, { token, body: { memberIds: [m] } });
    const d = await dues(m, Y + 1);
    expect(d.items.filter((x) => x.kind === "periodo").map((x) => x.status)).toEqual(["futura", "futura"]);
    expect(d.summary.inRegola).toBe(true);
  });

  it("rinnova gli iscritti del periodo precedente, esclusi i cessati", async () => {
    const c = await course("Forró avanzato");
    const p1 = await period(c.id, `${Y}-01`, `${Y}-03`, 5000);
    const p2 = await period(c.id, `${Y}-04`, `${Y}-06`, 6000);
    const a = await member("Dario");
    const b = await member("Elisa");
    await api(`/course-periods/${p1.id}/enroll`, { token, body: { memberIds: [a, b] } });
    await api(`/members/${b}/cease`, { token, body: { ceasedOn: `${Y}-03-31` } });
    const res = await api(`/course-periods/${p2.id}/enroll`, { token, body: { renewFromPeriodId: p1.id } });
    expect(await res.json()).toEqual({ enrolled: 1, alreadyEnrolled: 0 });
    const d = await dues(a);
    expect(d.items.find((x) => x.coursePeriodId === p2.id)!.amountCents).toBe(6000);
  });

  it("cambia il prezzo del periodo anche per gli iscritti non ancora paganti, se richiesto", async () => {
    const c = await course("Workshop lungo");
    const p = await period(c.id, `${Y}-09`, `${Y}-12`, 10000);
    const a = await member("Franco");
    await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [a] } });
    const stale = await api(`/course-periods/${p.id}`, { method: "PATCH", token, body: { amountCents: 9000 }, });
    expect(stale.status).toBe(200);
    const res = await api(`/course-periods/${p.id}`, { method: "PATCH", token, body: { amountCents: 8000, applyToUnpaid: true } });
    expect(((await res.json()) as { updatedDues: number }).updatedDues).toBe(1);
    expect((await dues(a)).items.find((x) => x.coursePeriodId === p.id)!.amountCents).toBe(8000);
  });

  it("non iscrive a periodi disattivati e annulla un'iscrizione come una quota", async () => {
    const c = await course("Prova");
    const p = await period(c.id, `${Y}-01`, `${Y}-01`, 1000);
    const a = await member("Gina");
    await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [a] } });
    const due = (await dues(a)).items.find((x) => x.coursePeriodId === p.id)!;
    expect((await api(`/dues/${due.id}/cancel`, { token, body: { reason: "Iscritto per errore" } })).status).toBe(204);
    await api(`/course-periods/${p.id}`, { method: "PATCH", token, body: { active: false } });
    expect(await errorCode(await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [a] } }))).toBe("period_inactive");
  });

  it("gli incassi dei periodi compaiono nel report per voce", async () => {
    const r = (await (await api(`/reports/income?year=${Y}`, { token })).json()) as { byKind: Record<string, number> };
    expect(r.byKind.periodo).toBeGreaterThanOrEqual(6000);
  });
});

describe("eliminazione di corsi e periodi", () => {
  it("elimina un corso senza iscritti, anche con iscrizioni annullate e mai pagate", async () => {
    const c = await course("Corso creato per sbaglio");
    const p = await period(c.id, `${Y}-04`, `${Y}-06`, 3000);
    const m = await member("Elena");
    await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [m] } });
    const due = (await dues(m)).items.find((x) => x.coursePeriodId === p.id)!;
    expect(await errorCode(await api(`/courses/${c.id}`, { token, method: "DELETE" }))).toBe("course_in_use");
    expect((await api(`/dues/${due.id}/cancel`, { token, body: { reason: "Sbaglio" } })).status).toBe(204);
    expect((await api(`/courses/${c.id}`, { token, method: "DELETE" })).status).toBe(204);
    const list = (await (await api("/courses", { token })).json()) as { items: Course[] };
    expect(list.items.some((x) => x.id === c.id)).toBe(false);
    expect((await api(`/courses/${c.id}`, { token, method: "DELETE" })).status).toBe(404);
  });

  it("non elimina un periodo con pagamenti, nemmeno se annullati", async () => {
    const c = await course("Corso con pagamenti");
    const p = await period(c.id, `${Y}-01`, `${Y}-02`, 2000);
    const vuoto = await period(c.id, `${Y}-03`, `${Y}-04`, 2000);
    const m = await member("Franco");
    await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [m] } });
    const due = (await dues(m)).items.find((x) => x.coursePeriodId === p.id)!;
    const pay = (await (await api("/payments", { token, body: { memberId: m, amountCents: 2000, method: "contanti", items: [{ dueId: due.id }] } })).json()) as { id: number };
    await api(`/payments/${pay.id}/void`, { token, body: { reason: "Prova" } });
    await api(`/dues/${due.id}/cancel`, { token, body: { reason: "Ritirato" } });
    expect(await errorCode(await api(`/course-periods/${p.id}`, { token, method: "DELETE" }))).toBe("period_in_use");
    expect(await errorCode(await api(`/courses/${c.id}`, { token, method: "DELETE" }))).toBe("course_in_use");
    expect((await api(`/course-periods/${vuoto.id}`, { token, method: "DELETE" })).status).toBe(204);
  });
});

describe("correzione dei mesi di un periodo", () => {
  it("sposta il periodo e le iscrizioni seguono il nuovo mese di inizio; il nome automatico si aggiorna", async () => {
    const c = await course("Corso da spostare");
    const p = await period(c.id, `${Y}-02`, `${Y}-04`, 4000);
    const m = await member("Gino");
    await api(`/course-periods/${p.id}/enroll`, { token, body: { memberIds: [m] } });
    const res = await api(`/course-periods/${p.id}`, { token, method: "PATCH", body: { from: `${Y}-03`, to: `${Y}-06` } });
    expect(res.status).toBe(200);
    const moved = ((await res.json()) as { period: Period }).period;
    expect(moved).toMatchObject({ from: `${Y}-03`, to: `${Y}-06`, months: 4, name: `mar–giu ${Y}` });
    const due = (await dues(m)).items.find((x) => x.coursePeriodId === p.id)! as Due & { month: number };
    expect(due.month).toBe(3);
    expect(await errorCode(await api(`/course-periods/${p.id}`, { token, method: "PATCH", body: { from: `${Y}-07`, to: `${Y}-06` } }))).toBe("validation_error");
  });
});
