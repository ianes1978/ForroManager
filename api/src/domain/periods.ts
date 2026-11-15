/**
 * Periodi mensili come numero assoluto di mesi: anno*12 + (mese-1).
 * Rende semplici confronti e intervalli (es. sospensioni da luglio ad agosto).
 */
export function periodOf(year: number, month: number): number {
  return year * 12 + (month - 1);
}

export function yearOf(period: number): number {
  return Math.floor(period / 12);
}

export function monthOf(period: number): number {
  return (period % 12) + 1;
}

/** 'YYYY-MM' → periodo. */
export function parseYearMonth(text: string): number {
  const m = /^(\d{4})-(\d{2})$/.exec(text);
  if (!m) throw new Error(`Mese non valido: ${text}`);
  return periodOf(Number(m[1]), Number(m[2]));
}

/** Periodo → 'YYYY-MM'. */
export function formatYearMonth(period: number): string {
  return `${yearOf(period)}-${String(monthOf(period)).padStart(2, "0")}`;
}

/** Periodo del mese che contiene la data 'YYYY-MM-DD'. */
export function periodOfDate(date: string): number {
  return periodOf(Number(date.slice(0, 4)), Number(date.slice(5, 7)));
}

export interface Interval {
  from: number;
  to: number;
}

export function overlaps(a: Interval, b: Interval): boolean {
  return a.from <= b.to && b.from <= a.to;
}

export function isSuspended(period: number, suspensions: Interval[]): boolean {
  return suspensions.some((s) => period >= s.from && period <= s.to);
}
