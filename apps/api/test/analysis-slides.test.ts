// Tests for the analysis → slide-data mapper (BRANDBOOK-STATUS §3.3).
//
// Run with: bun test test/analysis-slides.test.ts  (from apps/api/)

import { describe, expect, it } from "bun:test";
import {
  analysisFilesToSlides,
  insightsToSlides,
  parseInsights,
} from "@brandnana/schema/analysis-slides";

const VOICE_ORG = `#+TITLE: voice

* Forever-forward, plainspoken confidence                     :insight:voice:
  :PROPERTIES:
  :TYPE:    voice
  :GROUNDS: acme, brand:palette
  :END:
  The brand speaks in short declaratives. It never hedges and never
  shouts — the confidence is in the restraint.

* Calm, premium, never shouty                                 :insight:tone:
  :PROPERTIES:
  :TYPE:    tone
  :GROUNDS: brand:palette, ads:google
  :END:
  Muted palette, generous whitespace, slow cadence.
`;

describe("parseInsights", () => {
  it("extracts headline, type, grounds, and prose body", () => {
    const insights = parseInsights(VOICE_ORG);
    expect(insights).toHaveLength(2);

    const [voice, tone] = insights;
    expect(voice.type).toBe("voice");
    expect(voice.title).toBe("Forever-forward, plainspoken confidence");
    expect(voice.grounds).toEqual(["acme", "brand:palette"]);
    expect(voice.body).toContain("short declaratives");
    expect(voice.body).toContain("in the restraint."); // multi-line body joined

    expect(tone.type).toBe("tone");
    expect(tone.grounds).toEqual(["brand:palette", "ads:google"]);
  });

  it("ignores non-insight headlines and free text", () => {
    const org = `* Just a section heading\nsome notes\n* Real one :insight:audience:\n  :PROPERTIES:\n  :TYPE: audience\n  :GROUNDS: social:ig\n  :END:\n  Body.`;
    const insights = parseInsights(org);
    expect(insights).toHaveLength(1);
    expect(insights[0].type).toBe("audience");
  });

  it("falls back to the :insight:<type>: tag when the drawer omits TYPE", () => {
    const org = `* Headline :insight:positioning:\n  :PROPERTIES:\n  :GROUNDS: catalog:prices\n  :END:\n  Body.`;
    expect(parseInsights(org)[0].type).toBe("positioning");
  });

  it("handles a missing drawer (no grounds, body still captured)", () => {
    const org = `* Bare insight :insight:archetype:\n  The hero archetype, plainly.`;
    const [ins] = parseInsights(org);
    expect(ins.type).toBe("archetype");
    expect(ins.grounds).toEqual([]);
    expect(ins.body).toBe("The hero archetype, plainly.");
  });
});

describe("insightsToSlides", () => {
  it("emits one slide per insight, ordered by family", () => {
    // tone before voice in input, but FAMILY_ORDER puts voice before tone
    const slides = insightsToSlides([
      { type: "tone", title: "T", grounds: [], body: "b" },
      { type: "voice", title: "V", grounds: [], body: "b" },
    ]);
    expect(slides.map((s) => s.type)).toEqual(["voice", "tone"]);
    expect(slides[0].key).toBe("insight-voice");
  });

  it("dedupes keys for repeated families", () => {
    const slides = insightsToSlides([
      { type: "copy-ideas", title: "A", grounds: [], body: "b" },
      { type: "copy-ideas", title: "B", grounds: [], body: "b" },
    ]);
    expect(slides.map((s) => s.key)).toEqual(["insight-copy-ideas", "insight-copy-ideas-2"]);
  });

  it("drops parse-artifact insights with neither title nor body", () => {
    const slides = insightsToSlides([
      { type: "voice", title: "", grounds: [], body: "" },
      { type: "tone", title: "Calm", grounds: [], body: "" },
    ]);
    expect(slides.map((s) => s.type)).toEqual(["tone"]); // empty voice dropped
  });

  it("orders unknown families deterministically after known ones", () => {
    const slides = insightsToSlides([
      { type: "zzz-custom", title: "Z", grounds: [], body: "b" },
      { type: "voice", title: "V", grounds: [], body: "b" },
    ]);
    expect(slides[0].type).toBe("voice");
    expect(slides[1].type).toBe("zzz-custom");
  });
});

describe("analysisFilesToSlides", () => {
  it("parses many files and flattens to ordered slides", () => {
    const slides = analysisFilesToSlides([VOICE_ORG]);
    expect(slides.map((s) => s.type)).toEqual(["voice", "tone"]);
    expect(slides[0].grounds).toEqual(["acme", "brand:palette"]);
  });
});
