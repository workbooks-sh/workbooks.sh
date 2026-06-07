// Tests for the book-query OQL-subset matcher (extracted from book.ts, wb-t6zl).

import { describe, expect, it } from "bun:test";
import { applyOqlQuery, parseOrgHeadlines } from "./book-query.js";

const ORG = `* Brand
:PROPERTIES:
:DOMAIN: acme.com
:END:
intro

** Voice insight                                              :insight:voice:
:PROPERTIES:
:TYPE: voice
:END:
plainspoken

** Tone insight                                               :insight:tone:
:PROPERTIES:
:TYPE: tone
:END:
calm`;

describe("parseOrgHeadlines", () => {
  it("parses levels, titles, tags, and properties", () => {
    const hs = parseOrgHeadlines(ORG);
    expect(hs).toHaveLength(3);
    expect(hs[0]?.level).toBe(1);
    expect(hs[0]?.props.DOMAIN).toBe("acme.com");
    expect(hs[1]?.title).toBe("Voice insight");
    expect(hs[1]?.tags).toEqual(["insight", "voice"]);
  });
});

describe("applyOqlQuery", () => {
  const hs = parseOrgHeadlines(ORG);

  it("(tagged X) filters by tag", () => {
    const r = applyOqlQuery(hs, "(tagged voice)");
    expect(r.map((h) => h.title)).toEqual(["Voice insight"]);
  });

  it("(has property :KEY:) filters by property existence", () => {
    const r = applyOqlQuery(hs, "(has property :DOMAIN:)");
    expect(r.map((h) => h.title)).toEqual(["Brand"]);
  });

  it("(under \"path\") substring-matches the last segment against titles", () => {
    const r = applyOqlQuery(hs, '(under "Tone")');
    expect(r.map((h) => h.title)).toEqual(["Tone insight"]);
  });

  it("no predicate returns all headlines", () => {
    expect(applyOqlQuery(hs, "()")).toHaveLength(3);
  });
});
