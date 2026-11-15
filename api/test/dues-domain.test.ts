import { describe, expect, it } from "vitest";
import { allocate, compareForAllocation, dueLabel, dueStatus, splitCents, summarize } from "../src/domain/dues.ts";

const today = "2026-11-15";
const m = (month: number, amountCents = 2500, paidCents = 0, year = 2026) => ({ kind: "mensile" as const, year, month, amountCents, paidCents });

describe("stato delle quote", () => {
  it("distingue pagata, parziale, da pagare e futura", () => {
    expect(dueStatus(m(10, 2500, 2500), today)).toBe("pagata");
    expect(dueStatus(m(10, 2500, 1000), today)).toBe("parziale");
    expect(dueStatus(m(11), today)).toBe("da_pagare");
    expect(dueStatus(m(12), today)).toBe("futura");
    expect(dueStatus({ kind: "annuale", year: 2027, month: null, amountCents: 3000, paidCents: 0 }, today)).toBe("futura");
    expect(dueStatus({ kind: "prodotto", year: 2027, month: null, amountCents: 1500, paidCents: 0 }, today)).toBe("da_pagare");
  });

  it("una quota ridotta a zero risulta pagata", () => {
    expect(dueStatus(m(10, 0, 0), today)).toBe("pagata");
  });
});

describe("riepilogo del socio", () => {
  it("conta come arretrati solo le quote con periodo iniziato, i prodotti a parte", () => {
    const s = summarize(
      [
        { kind: "annuale", year: 2026, month: null, amountCents: 3000, paidCents: 3000 },
        m(10, 2500, 1000),
        m(11),
        m(12),
        { kind: "prodotto", year: 2026, month: null, amountCents: 1500, paidCents: 0 },
      ],
      today,
    );
    expect(s).toEqual({ arrearsCents: 4000, arrearsCount: 2, openChargesCents: 1500, openChargesCount: 1, inRegola: false });
  });

  it("è in regola anche con prodotti da saldare e quote future", () => {
    const s = summarize([m(12), { kind: "prodotto", year: 2026, month: null, amountCents: 1500, paidCents: 0 }], today);
    expect(s.inRegola).toBe(true);
  });
});

describe("ripartizione", () => {
  it("divide un pacchetto in parti intere che sommano al totale", () => {
    expect(splitCents(6500, 3)).toEqual([2167, 2167, 2166]);
    expect(splitCents(6500, 3).reduce((a, b) => a + b)).toBe(6500);
    expect(splitCents(1000, 4)).toEqual([250, 250, 250, 250]);
  });

  it("copre le quote nell'ordine fino a esaurire l'importo", () => {
    expect(allocate(4000, [{ id: 1, remainingCents: 2500 }, { id: 2, remainingCents: 2500 }, { id: 3, remainingCents: 2500 }])).toEqual([
      { dueId: 1, amountCents: 2500 },
      { dueId: 2, amountCents: 1500 },
    ]);
  });

  it("ordina associativa, poi mesi in ordine cronologico, poi prodotti", () => {
    const d = (id: number, kind: "annuale" | "mensile" | "prodotto", year: number, month: number | null) => ({ id, kind, year, month, chargedOn: "2026-01-01" });
    const sorted = [d(1, "prodotto", 2026, null), d(2, "mensile", 2027, 1), d(3, "mensile", 2026, 12), d(4, "annuale", 2026, null)].sort(compareForAllocation);
    expect(sorted.map((x) => x.id)).toEqual([4, 3, 2, 1]);
  });

  it("produce etichette leggibili", () => {
    expect(dueLabel({ kind: "mensile", year: 2026, month: 7 })).toBe("Mensile luglio 2026");
    expect(dueLabel({ kind: "annuale", year: 2026, month: null })).toBe("Quota associativa 2026");
    expect(dueLabel({ kind: "prodotto", year: 2026, month: null, productName: "Maglietta" })).toBe("Maglietta");
  });
});
