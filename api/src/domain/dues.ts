import { periodOf } from "./periods.ts";

export type DueKind = "annuale" | "mensile" | "prodotto";
export type DueStatus = "pagata" | "parziale" | "da_pagare" | "futura";

export interface DueLike {
  kind: DueKind;
  year: number;
  month: number | null;
  amountCents: number;
  paidCents: number;
}

/**
 * Stato di una quota alla data indicata:
 * - pagata: il pagato copre l'importo;
 * - parziale: c'è un pagamento ma non basta;
 * - da_pagare: periodo già iniziato (o addebito di un prodotto) e nulla pagato;
 * - futura: periodo non ancora iniziato (pagabile in anticipo).
 */
export function dueStatus(due: DueLike, today: string): DueStatus {
  if (due.paidCents >= due.amountCents) return "pagata";
  if (due.paidCents > 0) return "parziale";
  return isDueStarted(due, today) ? "da_pagare" : "futura";
}

export function isDueStarted(due: Pick<DueLike, "kind" | "year" | "month">, today: string): boolean {
  const year = Number(today.slice(0, 4));
  const month = Number(today.slice(5, 7));
  if (due.kind === "prodotto") return true;
  if (due.kind === "annuale") return due.year <= year;
  return periodOf(due.year, due.month!) <= periodOf(year, month);
}

export function remainingCents(due: Pick<DueLike, "amountCents" | "paidCents">): number {
  return Math.max(0, due.amountCents - due.paidCents);
}

export interface Summary {
  /** Quote (associative e mensili) con periodo iniziato e non coperte: determina se il socio è in regola. */
  arrearsCents: number;
  arrearsCount: number;
  /** Prodotti ed eventi addebitati e non ancora saldati: non incidono sull'essere in regola. */
  openChargesCents: number;
  openChargesCount: number;
  inRegola: boolean;
}

export function summarize(dues: DueLike[], today: string): Summary {
  let arrearsCents = 0, arrearsCount = 0, openChargesCents = 0, openChargesCount = 0;
  for (const d of dues) {
    const rest = remainingCents(d);
    if (rest === 0) continue;
    if (d.kind === "prodotto") {
      openChargesCents += rest;
      openChargesCount++;
    } else if (isDueStarted(d, today)) {
      arrearsCents += rest;
      arrearsCount++;
    }
  }
  return { arrearsCents, arrearsCount, openChargesCents, openChargesCount, inRegola: arrearsCents === 0 };
}

/** Ordine di copertura: prima l'associativa, poi i mesi in ordine, infine i prodotti per data. */
export function compareForAllocation(
  a: { kind: DueKind; year: number; month: number | null; chargedOn: string; id: number },
  b: { kind: DueKind; year: number; month: number | null; chargedOn: string; id: number },
): number {
  const rank = (d: { kind: DueKind }) => (d.kind === "annuale" ? 0 : d.kind === "mensile" ? 1 : 2);
  if (rank(a) !== rank(b)) return rank(a) - rank(b);
  if (a.year !== b.year) return a.year - b.year;
  if ((a.month ?? 0) !== (b.month ?? 0)) return (a.month ?? 0) - (b.month ?? 0);
  if (a.chargedOn !== b.chargedOn) return a.chargedOn < b.chargedOn ? -1 : 1;
  return a.id - b.id;
}

/**
 * Ripartisce un totale in n parti intere che differiscono al massimo di 1 centesimo
 * (le prime parti ricevono l'eventuale resto). Usato per i pacchetti.
 */
export function splitCents(total: number, parts: number): number[] {
  const base = Math.floor(total / parts);
  const rest = total - base * parts;
  return Array.from({ length: parts }, (_, i) => base + (i < rest ? 1 : 0));
}

/** Ripartisce un pagamento sulle quote nell'ordine dato, fino a esaurimento. */
export function allocate(amountCents: number, dues: { id: number; remainingCents: number }[]): { dueId: number; amountCents: number }[] {
  const out: { dueId: number; amountCents: number }[] = [];
  let left = amountCents;
  for (const d of dues) {
    if (left <= 0) break;
    const part = Math.min(left, d.remainingCents);
    if (part > 0) {
      out.push({ dueId: d.id, amountCents: part });
      left -= part;
    }
  }
  return out;
}

const MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"];

export function dueLabel(d: { kind: DueKind; year: number; month: number | null; productName?: string | null }): string {
  if (d.kind === "prodotto") return d.productName ?? "Prodotto";
  if (d.kind === "annuale") return `Quota associativa ${d.year}`;
  return `Mensile ${MESI[d.month! - 1]} ${d.year}`;
}
