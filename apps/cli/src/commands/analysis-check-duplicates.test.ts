// Tests for the §3.1 duplicate-insight quality gate (wb-syjo).

import { describe, expect, it } from "bun:test";
import { checkDuplicateInsights, type ParsedInsight } from "./analysis-check.js";

function ins(type: string, headline: string): ParsedInsight {
  return { file: `${type}.org`, headline, type, grounds: ["x"], groundsRaw: "x", body: "b".repeat(80), bodyLen: 80 };
}

describe("checkDuplicateInsights", () => {
  it("passes when same-type insights are distinct", () => {
    const r = checkDuplicateInsights([
      ins("voice", "* Plainspoken, forever-forward confidence :insight:voice:"),
      ins("voice", "* Warmth carried by restraint, never shouty :insight:voice:"),
    ]);
    expect(r.pass).toBe(true);
  });

  it("flags near-identical same-type headlines", () => {
    const r = checkDuplicateInsights([
      ins("voice", "* Plainspoken forever-forward confidence :insight:voice:"),
      ins("voice", "* Plainspoken, forever-forward confidence! :insight:voice:"),
    ]);
    expect(r.pass).toBe(false);
    expect(r.violations[0]).toContain("near-duplicate");
  });

  it("does NOT flag identical headlines across DIFFERENT types", () => {
    const r = checkDuplicateInsights([
      ins("voice", "* Confident restraint :insight:voice:"),
      ins("tone", "* Confident restraint :insight:tone:"),
    ]);
    expect(r.pass).toBe(true);
  });

  it("passes on an empty insight set", () => {
    expect(checkDuplicateInsights([]).pass).toBe(true);
  });
});
