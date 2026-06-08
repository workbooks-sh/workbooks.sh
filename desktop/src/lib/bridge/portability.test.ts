// wb-unzn.25 P3 — pure-helper coverage for the portability bridge.
//
// Lives at *.test.ts (not *.svelte.test.ts) because we exercise only
// the typed exports — tier comparison + tooltip copy. The reactive
// store itself relies on Svelte 5 runes, which need the svelte
// preprocessor; vitest in this repo runs vanilla and would fail to
// parse a `.svelte.ts` file. Store integration is covered manually
// via the desktop UI; this guards the regressions that don't depend
// on runtime mounting.

import { describe, it, expect } from "vitest";
import {
  tierCoversRequired,
  tierLabel,
  tierExplanation,
  type Tier,
} from "./portability.svelte";

describe("tierCoversRequired", () => {
  it("treats every tier as covering itself", () => {
    const tiers: Tier[] = ["browser", "live-url", "desktop"];
    for (const t of tiers) {
      expect(tierCoversRequired(t, t)).toBe(true);
    }
  });

  it("treats a looser declared tier as failing a stricter required one", () => {
    expect(tierCoversRequired("browser", "live-url")).toBe(false);
    expect(tierCoversRequired("browser", "desktop")).toBe(false);
    expect(tierCoversRequired("live-url", "desktop")).toBe(false);
  });

  it("treats a stricter declared tier as covering a looser required one", () => {
    // The declared tier is the headroom the recipient gets; declaring
    // `desktop` for a workbook that only needs `browser` is allowed
    // (the recipient has more than enough). The validator must permit
    // this, per portability.org build-time rules.
    expect(tierCoversRequired("desktop", "browser")).toBe(true);
    expect(tierCoversRequired("desktop", "live-url")).toBe(true);
    expect(tierCoversRequired("live-url", "browser")).toBe(true);
  });
});

describe("tierLabel", () => {
  it("returns a stable lowercase identifier", () => {
    expect(tierLabel("browser")).toBe("browser");
    expect(tierLabel("live-url")).toBe("live-url");
    expect(tierLabel("desktop")).toBe("desktop");
  });
});

describe("tierExplanation", () => {
  it("returns a non-empty user-facing sentence for every tier", () => {
    const tiers: Tier[] = ["browser", "live-url", "desktop"];
    for (const t of tiers) {
      const msg = tierExplanation(t);
      expect(msg.length).toBeGreaterThan(0);
      // Each sentence ends with a period — sanity-check the format
      // matches the convention used elsewhere in the tooltip copy.
      expect(msg.endsWith(".")).toBe(true);
    }
  });

  it("mentions each tier's recipient requirement", () => {
    expect(tierExplanation("browser").toLowerCase()).toContain("browser");
    expect(tierExplanation("live-url").toLowerCase()).toContain("hosted vm");
    expect(tierExplanation("desktop").toLowerCase()).toContain("desktop");
  });
});
