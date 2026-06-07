// Tests that data-driven insight slides are wired into the presentation deck
// (BRANDBOOK-STATUS §3.3). Run with: bun test test/insight-slides-render.test.ts

import { describe, expect, it } from "bun:test";
import { renderPresentation, type BookData } from "../src/book/presentation-shell.js";
import type { InsightSlide } from "@brandnana/schema/analysis-slides";

function minimalBookData(insightSlides: InsightSlide[]): BookData {
  return {
    spec: {
      slug: "acme",
      title: "Acme Brand Book",
      generated_at: "2026-06-05",
      generator: "test",
      data_source: "seed",
    },
    brand: {
      name: "Acme",
      domain: "acme.com",
      category: "test",
      tagline: "t",
      description: "d",
      logo_svg_url: "",
      primary_font: "Inter",
      secondary_font: "Inter",
      social: [],
    },
    palette: [],
    type_samples: [],
    products: [],
    ads: [],
    competitors: [],
    voice_notes: [],
    extras: {},
    timeline: [],
    curated: {
      cover_headline: "h",
      cover_subhead: "s",
      slide_order: ["cover"],
      section_blurbs: {},
      source: "fallback",
    },
    insight_slides: insightSlides,
  };
}

const SLIDES: InsightSlide[] = [
  {
    key: "insight-voice",
    type: "voice",
    title: "Forever-forward, plainspoken confidence",
    body: "Short declaratives; never hedges.",
    grounds: ["acme", "brand:palette"],
  },
];

describe("renderPresentation — data-driven insight slides", () => {
  const html = renderPresentation({
    data: minimalBookData(SLIDES),
    workbookSpec: {},
    sourceBundleBase64: "",
  });

  it("embeds the insight slide data (title, body, grounds) in the page", () => {
    expect(html).toContain("Forever-forward, plainspoken confidence");
    expect(html).toContain("Short declaratives; never hedges.");
    expect(html).toContain("brand:palette");
  });

  it("ships the generic insight-slide builder + grounds styling", () => {
    expect(html).toContain("function slideInsight");
    expect(html).toContain("data.insight_slides");
    expect(html).toContain(".grounds");
    expect(html).toContain(".ground");
  });

  it("renders with no insight slides (empty array) without breaking", () => {
    const empty = renderPresentation({
      data: minimalBookData([]),
      workbookSpec: {},
      sourceBundleBase64: "",
    });
    expect(empty).toContain("function slideInsight"); // builder always present
    expect(empty).toContain('"insight_slides":[]'); // empty data round-trips
  });
});
