import { describe, expect, it } from "vitest";
import { formatYearMonth, isSuspended, overlaps, parseYearMonth, periodOf, periodOfDate } from "../src/domain/periods.ts";

describe("periodi mensili", () => {
  it("convertono tra AAAA-MM e numero assoluto, anche a cavallo d'anno", () => {
    expect(parseYearMonth("2026-12") + 1).toBe(parseYearMonth("2027-01"));
    expect(formatYearMonth(periodOf(2027, 1))).toBe("2027-01");
    expect(periodOfDate("2026-07-31")).toBe(periodOf(2026, 7));
  });

  it("riconoscono sovrapposizioni e mesi sospesi, estremi inclusi", () => {
    const estate = { from: periodOf(2026, 7), to: periodOf(2026, 8) };
    expect(overlaps(estate, { from: periodOf(2026, 8), to: periodOf(2026, 9) })).toBe(true);
    expect(overlaps(estate, { from: periodOf(2026, 9), to: periodOf(2026, 10) })).toBe(false);
    expect(isSuspended(periodOf(2026, 7), [estate])).toBe(true);
    expect(isSuspended(periodOf(2026, 9), [estate])).toBe(false);
  });
});
