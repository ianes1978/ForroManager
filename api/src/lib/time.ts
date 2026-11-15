/** Istante corrente in formato ISO 8601 UTC senza millisecondi, es. 2026-11-15T10:00:00Z. */
export function nowIso(now: Date = new Date()): string {
  return now.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function addSeconds(iso: string, seconds: number): string {
  return nowIso(new Date(Date.parse(iso) + seconds * 1000));
}

/** Data odierna 'YYYY-MM-DD' (UTC). */
export function todayIso(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10);
}
