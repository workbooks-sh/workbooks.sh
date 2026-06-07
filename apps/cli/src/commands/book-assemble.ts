// `book assemble <spec.json>` — assemble a deck-v2 HTML from a slide spec.
//
// Replaces the per-run python deck-builder: the Designer was hand-writing a
// ~1400-line build_deck.py EVERY run (CSS shell + slide wrappers + doc assembly
// + content). The boilerplate now lives HERE, once; the Designer composes only
// the brand-specific spec {palette, slides}. No python in the agent (wb-x7md).
//
// The design-system CSS is book-deck.css (palette-agnostic — it reads CSS vars);
// the brand palette is generated into :root from the spec, so nothing is baked.
import { readFileSync, writeFileSync, statSync, readdirSync } from "node:fs";
import { join } from "node:path";
import deckCss from "./book-deck.css" with { type: "text" };

/** The 11 design tokens the CSS shell reads via `var(--…)`. */
export interface Palette {
  stageBg: string;
  fg: string;
  fgMuted: string;
  fgSubtle: string;
  primary: string;
  secondary: string;
  accent: string;
  bone: string;
  line: string;
  fontDisplay: string;
  fontBody: string;
}

/** One slide. Structural slides carry typed fields; a `content` slide carries
 *  the inner component HTML the Designer composed (using design-system classes). */
export type Slide =
  | { type: "splash"; eyebrow: string; h1: string; sub: string; img: string }
  | { type: "act-divider"; roman: string; num: string; title: string; sub?: string }
  | { type: "end-card"; mark: string; h1: string; line: string; meta: string }
  | { type: "content"; html: string; density?: "light" | "dense" | "fill"; cls?: string; label?: string };

export interface DeckSpec {
  title: string;
  /** right-hand credit repeated on every content slide (e.g. a tagline) */
  creditR?: string;
  palette: Palette;
  slides: Slide[];
}

function rootVars(p: Palette): string {
  return [
    `--stage-bg:${p.stageBg}`,
    `--fg:${p.fg}`,
    `--fg-muted:${p.fgMuted}`,
    `--fg-subtle:${p.fgSubtle}`,
    `--primary:${p.primary}`,
    `--secondary:${p.secondary}`,
    `--accent:${p.accent}`,
    `--bone:${p.bone}`,
    `--line:${p.line}`,
    `--font-display:${p.fontDisplay}`,
    `--font-body:${p.fontBody}`,
  ].join(";");
}

// The 4 structural wrappers (verbatim from the proven python build_deck.py).
// Fields are passed through (the Designer supplies display-ready strings, as it
// did in python) — do NOT HTML-escape, or pre-escaped entities double-encode.
function renderSlide(s: Slide, spec: DeckSpec): string {
  switch (s.type) {
    case "splash":
      return (
        `<section class="slide splash">` +
        `<img src="${s.img}" loading="lazy" onerror="this.closest('.splash').classList.add('img-fail')">` +
        `<div class="splash-copy"><div class="splash-eyebrow">${s.eyebrow}</div>` +
        `<h1>${s.h1}</h1><div class="splash-sub">${s.sub}</div></div></section>`
      );
    case "act-divider":
      return (
        `<section class="slide act-divider"><div>` +
        `<div class="ad-kicker">Act ${s.roman}</div>` +
        `<div class="ad-numeral">${s.num}</div>` +
        `<div class="ad-title">${s.title}</div>` +
        `<div class="ad-sub">${s.sub ?? ""}</div></div></section>`
      );
    case "end-card":
      return (
        `<section class="slide light"><div class="end-card">` +
        `<div class="ec-mark">${s.mark}</div><h1>${s.h1}</h1>` +
        `<div class="ec-line">${s.line}</div><div class="ec-meta">${s.meta}</div></div></section>`
      );
    case "content": {
      const density = s.density ?? "light";
      const cls = s.cls ? ` ${s.cls}` : "";
      const label = s.label ?? spec.title;
      const creditR = spec.creditR ?? "";
      return (
        `<section class="slide ${density}${cls}">` +
        `<div class="credit">${label}</div><div class="credit-r">${creditR}</div>` +
        `${s.html}</section>`
      );
    }
    default: {
      const _never: never = s;
      return _never;
    }
  }
}

// reveal.js turns the deck into a real navigable presentation (arrow keys,
// fullscreen, slide URLs) without touching the 1280×720 slide design — reveal
// scales the fixed stage to the viewport. The bridge rule defers slide
// visibility to reveal (our `.slide{display:flex}` would otherwise stack them);
// `.reveal .slides>section.slide` out-specifies `.slide`, so reveal's `.present`
// class drives which slide shows. transition:none = hard cuts (no fade/wipe).
const REVEAL_VER = "5.1.0";
const revealHead =
  `<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reveal.js@${REVEAL_VER}/dist/reveal.css">\n` +
  `<style>html,body{background:var(--stage-bg)}` +
  `.reveal .slides{text-align:left}` +
  `.reveal .slides>section.slide{display:none;padding:54px 64px}` +
  `.reveal .slides>section.slide.present{display:flex}</style>`;
const revealBody =
  `<script src="https://cdn.jsdelivr.net/npm/reveal.js@${REVEAL_VER}/dist/reveal.js"></script>\n` +
  `<script>Reveal.initialize({width:1280,height:720,margin:0,center:false,` +
  `hash:true,controls:true,progress:true,transition:"none"});</script>`;

/** Assemble a full single-file deck HTML from a spec (doc shell + CSS + slides). */
export function assembleDeck(spec: DeckSpec): string {
  const css = `<style>\n:root{${rootVars(spec.palette)}}\n${deckCss}\n</style>`;
  const body = spec.slides.map((s) => renderSlide(s, spec)).join("\n");
  return (
    `<!DOCTYPE html>\n<html lang="en">\n<head>\n` +
    `<meta charset="UTF-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n` +
    `<title>${spec.title}</title>\n${revealHead}\n${css}\n</head>\n<body>\n` +
    `<div class="reveal">\n<div class="slides">\n${body}\n</div>\n</div>\n${revealBody}\n</body>\n</html>\n`
  );
}

/**
 * Read a DeckSpec from EITHER a single spec.json file OR a DIRECTORY of per-slide
 * files. The directory form (deck.json = {title, creditR?, palette}; every other
 * NN-*.json = one Slide, assembled in filename order) lets the Designer write the
 * deck INCREMENTALLY — many small files — instead of emitting all ~40 slides in
 * one giant LLM turn (which hung a run; wb-69gx).
 */
function readSpec(specPath: string): DeckSpec {
  if (!statSync(specPath).isDirectory()) {
    return JSON.parse(readFileSync(specPath, "utf8")) as DeckSpec;
  }
  const meta = JSON.parse(readFileSync(join(specPath, "deck.json"), "utf8")) as Omit<DeckSpec, "slides">;
  const slides = readdirSync(specPath)
    .filter((f) => f.endsWith(".json") && f !== "deck.json")
    .sort()
    .map((f) => JSON.parse(readFileSync(join(specPath, f), "utf8")) as Slide);
  return { ...meta, slides };
}

/** Read a spec (file or directory), assemble, write the deck. Returns counts. */
export function runAssemble(specPath: string, outPath: string): { slides: number; bytes: number } {
  const spec = readSpec(specPath);
  if (!spec?.palette || !Array.isArray(spec.slides) || spec.slides.length === 0) {
    throw new Error(
      "spec must be {title, palette:{…11 tokens}, slides:[…]} as ONE .json, OR a DIRECTORY with deck.json " +
        "{title,palette} + NN-*.json slide files (one Slide each). See DeckSpec in book-assemble.ts",
    );
  }
  const html = assembleDeck(spec);
  writeFileSync(outPath, html);
  return { slides: spec.slides.length, bytes: html.length };
}
