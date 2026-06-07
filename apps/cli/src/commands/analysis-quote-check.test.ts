// Tests for §3.2 testimonial quote byte-provenance (wb-syjo / wb-on95).

import { describe, expect, it } from "bun:test";
import { checkQuoteGrounding, extractQuotes } from "./analysis-quote-check.js";
import type { ParsedInsight } from "./analysis-check.js";

function testimonial(body: string): ParsedInsight {
  return { file: "testimonials.org", headline: "* T :insight:testimonials:", type: "testimonials", grounds: ["x"], groundsRaw: "x", body, bodyLen: body.length };
}

const SUBSTRATE = [
  {
    name: "social/ig.org",
    text: `* A review :social:point:\n  :BODY:\n  This jacket changed how I think about rain. Worth every penny.`,
  },
];

describe("extractQuotes", () => {
  it("pulls straight and smart double-quoted spans", () => {
    expect(extractQuotes('She said "worth every penny" loudly.')).toEqual(["worth every penny"]);
    expect(extractQuotes("He said “changed how I think” calmly.")).toEqual(["changed how I think"]);
  });

  it("ignores apostrophes / single quotes", () => {
    expect(extractQuotes("it's a brand's voice")).toEqual([]);
  });
});

describe("checkQuoteGrounding", () => {
  it("passes when the quote appears in the substrate", () => {
    const r = checkQuoteGrounding(
      [testimonial('Customers rave: "worth every penny" again and again.')],
      SUBSTRATE,
    );
    expect(r.pass).toBe(true);
  });

  it("fails on an invented quote not in the substrate", () => {
    const r = checkQuoteGrounding(
      [testimonial('A glowing note: "this is the best purchase of my entire life".')],
      SUBSTRATE,
    );
    expect(r.pass).toBe(false);
    expect(r.violations[0]).toContain("not found in harvested data");
  });

  it("ignores non-testimonial insights", () => {
    const voice: ParsedInsight = {
      file: "voice.org", headline: "* V :insight:voice:", type: "voice",
      grounds: ["x"], groundsRaw: "x", body: 'They say "totally made up phrase here".', bodyLen: 40,
    };
    expect(checkQuoteGrounding([voice], SUBSTRATE).pass).toBe(true);
  });

  it("skips quotes shorter than the minimum length", () => {
    const r = checkQuoteGrounding([testimonial('They said "love it" once.')], SUBSTRATE);
    expect(r.pass).toBe(true); // "love it" too short to verify → not flagged
  });
});
