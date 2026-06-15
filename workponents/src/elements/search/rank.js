// workponents · search — the zero-dep ranking helper (in-WASM-tier fuzzy/score).
//
// The engine answers the "which rows match" question with SQL (WHERE … LIKE). But
// a command palette wants ORDERED RELEVANCE over a small, in-memory command set —
// a subsequence/prefix fuzzy match with a score, not a substring filter. That
// ranking is pure data (no DOM, no CSS), so it lives here in the domain dir and is
// shared by <wb-command> (command set) and <wb-search> (client-side re-rank of the
// engine's candidate rows). Deliberately tiny — no Fuse.js, no deps.
//
// Algorithm: a forgiving subsequence matcher (every query char must appear in
// order) with bonuses for: exact match, prefix, word-boundary starts, and
// consecutive runs; penalties for gaps + leading distance. Returns null on no
// match so callers can drop non-matches, or a { score, ranges } on a hit so the
// UI can highlight the matched character ranges.

/**
 * Fuzzy-score `query` against `text`.
 * @returns {{ score:number, ranges:[number,number][] } | null}
 */
export function fuzzyScore(query, text) {
  const q = String(query ?? "");
  const t = String(text ?? "");
  if (!q) return { score: 0, ranges: [] };
  if (!t) return null;

  const ql = q.toLowerCase();
  const tl = t.toLowerCase();

  // Fast wins.
  if (tl === ql) return { score: 1000, ranges: [[0, t.length]] };
  const idx = tl.indexOf(ql);
  if (idx === 0) return { score: 800 - t.length, ranges: [[0, q.length]] };
  if (idx > 0) {
    const boundary = idx === 0 || /[\s\-_/.]/.test(t[idx - 1]);
    return { score: (boundary ? 600 : 400) - idx - t.length * 0.1, ranges: [[idx, idx + q.length]] };
  }

  // Subsequence match with positional bonuses.
  let qi = 0, ti = 0, score = 0, lastMatch = -2;
  const hits = [];
  while (qi < ql.length && ti < tl.length) {
    if (ql[qi] === tl[ti]) {
      let s = 10;
      if (ti === lastMatch + 1) s += 15;                       // consecutive run
      if (ti === 0 || /[\s\-_/.]/.test(t[ti - 1])) s += 20;     // word-boundary start
      score += s;
      hits.push(ti);
      lastMatch = ti;
      qi++;
    } else {
      score -= 1; // gap penalty
    }
    ti++;
  }
  if (qi < ql.length) return null; // not all query chars consumed → no match
  score -= ti - lastMatch;         // trailing distance
  return { score, ranges: rangesFromHits(hits) };
}

/** Collapse sorted hit indices into [start,end) character ranges for highlight. */
function rangesFromHits(hits) {
  const ranges = [];
  for (const i of hits) {
    const last = ranges[ranges.length - 1];
    if (last && last[1] === i) last[1] = i + 1;
    else ranges.push([i, i + 1]);
  }
  return ranges;
}

/**
 * Rank `items` against `query`, returning the matches sorted best-first.
 * @param {string} query
 * @param {Array<any>} items
 * @param {(item:any)=>string} keyOf  text to match per item
 * @returns {Array<{ item:any, score:number, ranges:[number,number][] }>}
 */
export function rank(query, items, keyOf) {
  const q = String(query ?? "").trim();
  if (!q) return items.map((item) => ({ item, score: 0, ranges: [] }));
  const out = [];
  for (const item of items) {
    const r = fuzzyScore(q, keyOf(item));
    if (r) out.push({ item, score: r.score, ranges: r.ranges });
  }
  out.sort((a, b) => b.score - a.score);
  return out;
}

/**
 * Render `text` with matched `ranges` wrapped in <mark> (HTML-escaped).
 * @param {string} text
 * @param {[number,number][]} ranges
 */
export function highlight(text, ranges) {
  const t = String(text ?? "");
  if (!ranges || !ranges.length) return esc(t);
  let out = "", at = 0;
  for (const [s, e] of ranges) {
    out += esc(t.slice(at, s)) + "<mark>" + esc(t.slice(s, e)) + "</mark>";
    at = e;
  }
  return out + esc(t.slice(at));
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}
