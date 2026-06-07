import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assembleDeck, runAssemble, type DeckSpec } from "./book-assemble.js";

const palette: DeckSpec["palette"] = {
  stageBg: "#fcf9f4",
  fg: "#1a1410",
  fgMuted: "#5a4a3e",
  fgSubtle: "#8a7a6e",
  primary: "#040404",
  secondary: "#b1624c",
  accent: "#a75742",
  bone: "#f9f1e9",
  line: "rgba(26,20,16,.10)",
  fontDisplay: "Georgia,serif",
  fontBody: "Inter,sans-serif",
};

const spec: DeckSpec = {
  title: "Test Brand Book",
  creditR: "forever test.",
  palette,
  slides: [
    { type: "splash", eyebrow: "Test", h1: "Forever Test.", sub: "A test deck.", img: "https://x/x.jpg" },
    { type: "act-divider", roman: "I", num: "01", title: "Identity", sub: "the story" },
    { type: "content", density: "light", html: '<div class="stat-hero"><div class="sh-value">42</div></div>' },
    { type: "end-card", mark: "✦", h1: "Thanks", line: "fin", meta: "2026" },
  ],
};

test("assembleDeck: shell + palette→:root + design-system CSS + slides", () => {
  const html = assembleDeck(spec);
  expect(html).toContain('class="reveal"'); // gate's shell check
  expect(html).toContain("<title>Test Brand Book</title>");
  expect(html).toContain("--primary:#040404"); // palette generated into :root
  expect(html).toContain("--font-display:Georgia,serif");
  expect(html).toContain(".stat-hero"); // the design-system CSS shell is inlined
  expect(html).toContain("Forever Test."); // splash content
  expect(html).toContain('class="slide act-divider"'); // structural wrapper
  expect(html).toContain('<div class="sh-value">42</div>'); // content slide inner HTML
  expect(html).toContain('class="credit-r">forever test.'); // creditR on content slide
  expect((html.match(/<section /g) || []).length).toBe(4); // one section per slide
});

test("runAssemble: round-trips spec JSON → written deck file", () => {
  const dir = mkdtempSync(join(tmpdir(), "bn-assemble-"));
  const specPath = join(dir, "spec.json");
  const outPath = join(dir, "deck.html");
  writeFileSync(specPath, JSON.stringify(spec));
  const r = runAssemble(specPath, outPath);
  expect(r.slides).toBe(4);
  expect(r.bytes).toBeGreaterThan(1000);
  expect(readFileSync(outPath, "utf8")).toContain('class="reveal"');
});

test("runAssemble: assembles from a DIRECTORY of per-slide files (wb-69gx)", () => {
  const dir = mkdtempSync(join(tmpdir(), "bn-assemble-dir-"));
  writeFileSync(join(dir, "deck.json"), JSON.stringify({ title: spec.title, creditR: spec.creditR, palette }));
  spec.slides.forEach((s, i) =>
    writeFileSync(join(dir, `${String(i + 1).padStart(2, "0")}-s.json`), JSON.stringify(s)),
  );
  const outPath = join(dir, "out.html");
  const r = runAssemble(dir, outPath);
  expect(r.slides).toBe(4);
  const html = readFileSync(outPath, "utf8");
  expect(html).toContain('class="reveal"');
  expect(html).toContain("Forever Test."); // splash slide from the dir
  expect((html.match(/<section /g) || []).length).toBe(4); // same result as the single-file form
});

test("runAssemble: rejects a malformed spec", () => {
  const dir = mkdtempSync(join(tmpdir(), "bn-assemble-bad-"));
  const specPath = join(dir, "bad.json");
  writeFileSync(specPath, JSON.stringify({ title: "x", slides: [] }));
  expect(() => runAssemble(specPath, join(dir, "out.html"))).toThrow();
});
