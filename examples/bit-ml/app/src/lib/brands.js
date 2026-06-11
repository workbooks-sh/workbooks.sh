// Brand registry (DESIGN.md §"inline brand logos"). Curated, INLINED full-color
// SVG marks for the brands the seed content names. Sourced per skills/icons.org:
//   svgl (full color) → lobehub *-color → simple-icons (monochrome, brand hex).
// Each mark is normalized to a 24-viewBox, sized by the wrapper to ~1em (so it
// scales with its heading), and carries its OWN color (monochrome marks get the
// brand hex baked into fill) — these are the SECOND sanctioned color exception.
//
// Honesty law: a brand with no good logo gets `svg: null` (or is simply absent)
// and BrandTag renders the name alone — never a broken/approximated mark.
//
// Sources used (2026-06-10):
//   google     — lobehub google-color (clean 4-color G)
//   deepmind   — lobehub deepmind-color (#4285F4)
//   nvidia     — simple-icons, brand green #76b900
//   amazon     — simple-icons, brand orange #FF9900
//   anthropic  — simple-icons, brand ink #181818
//   openai     — simple-icons, brand ink #000000
//   intel      — simple-icons, brand blue #0068B5
//   tsmc/micron/bloomberg/ECMWF/EU — no clean mark → name-only (svg:null)

// ── full-color marks ────────────────────────────────────────────────────────
import { BRAND_DATA } from './brand-data.js';

// The registry is GENERATED from the glyphs toolkit (scripts/build-brands.mjs):
// key → { name (display), match: [aliases the scanner accepts], svg | null }.
export const BRANDS = Object.fromEntries(
  Object.entries(BRAND_DATA).map(([k, b]) => [k, { name: b.name, svg: b.svg }]),
);

// ── brandify(text) → HTML string ─────────────────────────────────────────────
// Scan plain text for registered brand names (word-boundary, case-insensitive,
// LONGEST-MATCH-FIRST so "OpenAI" wins over a stray "Open"). On the FIRST match
// of a given brand within this call, emit the mark + name; later mentions of the
// same brand render as plain text (tasteful: logo once per block). `seen` is
// per-call so each render block tracks its own first-mentions.
//
// Returns an HTML string for {@html}. Text is HTML-escaped; only our own
// <span>/<svg> wrappers are injected — brand SVGs are first-party constants.

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
function esc(s) { return s.replace(/[&<>"']/g, (c) => ESC[c]); }

// Build the match list once: [{ key, name, re }] sorted by name length desc.
// 'EU' is intentionally NOT auto-matched (too short / ambiguous in prose); it
// stays in the registry for explicit use but is excluded from the scanner.
const SKIP_AUTOMATCH = new Set(['eu']);
const MATCHERS = Object.entries(BRAND_DATA)
  .filter(([key]) => !SKIP_AUTOMATCH.has(key))
  // explode each brand's aliases into individual matchers (so "Claude Code"
  // and "Claude" both resolve to the claude mark)
  .flatMap(([key, b]) => (b.match || [b.name]).map((alias) => ({ key, name: alias })))
  .sort((a, b) => b.name.length - a.name.length)
  .map((m) => ({
    ...m,
    re: new RegExp(`\\b${m.name.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\$&')}\\b`, 'i'),
  }));

// One <span class="brand"> wrapper: mark (if any) + the matched (original-cased)
// text. The mark span is em-scaled so it grows with its heading.
function wrap(key, matchedText) {
  const b = BRANDS[key];
  const mark = b.svg
    ? `<span class="brand-mark">${b.svg}</span>`
    : '';
  // mark sits AFTER the word (never before), tucked tight to it
  return `<span class="brand">${esc(matchedText)}${mark}</span>`;
}

export function brandify(text) {
  if (!text) return '';
  const seen = new Set();           // first-mention tracking, per call
  let out = '';
  let rest = String(text);

  // Greedy left-to-right scan: at each step find the earliest brand match among
  // all matchers; among ties at the same index, the longest name wins (MATCHERS
  // is length-desc, and we prefer the lowest index then the first matcher).
  while (rest.length) {
    let best = null; // { index, length, key, matchedText }
    for (const m of MATCHERS) {
      const hit = m.re.exec(rest);
      if (!hit) continue;
      const idx = hit.index;
      const len = hit[0].length;
      if (!best || idx < best.index || (idx === best.index && len > best.length)) {
        best = { index: idx, length: len, key: m.key, matchedText: hit[0] };
      }
    }
    if (!best) { out += esc(rest); break; }

    out += esc(rest.slice(0, best.index));
    const tail = rest.slice(best.index + best.length);
    // POSITION RULE: a logo never opens or closes a headline — it must be within
    // the words. "first" = nothing but whitespace precedes it in the whole text;
    // "last" = nothing but whitespace/terminal punctuation follows it.
    const atStart = out.trim() === '';
    const atEnd = tail.replace(/[\s.,;:!?—–-]+$/, '').trim() === '';
    if (seen.has(best.key) || atStart || atEnd) {
      out += esc(best.matchedText);            // plain — no mark
    } else {
      seen.add(best.key);
      out += wrap(best.key, best.matchedText);
    }
    rest = tail;
  }
  return out;
}
