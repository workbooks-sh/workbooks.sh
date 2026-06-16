// search · the POWERED tier — MiniSearch behind the <search-box> / <search-command>
// data floor.
//
// The floor (`search-box._buildSql` / `search-command._runData`) answers "which
// rows match" with the engine: `… WHERE col LIKE '%term%'` over getEngine() —
// a case-insensitive SUBSTRING filter, plus (for the command set) the in-WASM
// fuzzy `rank.js`. That floor is zero-dependency and always available.
//
// This module is the powered alternative: a client-side MiniSearch index built
// over the SAME source rows (the rows the engine returns for the source), giving
// RANKED, TYPO-TOLERANT, PREFIX search that LIKE can't express — relevance order,
// near-miss recall (`recieve`→`receive`), and `ana`→`analytics` prefix hits. Only
// the ranking/match engine swaps; the data source (getEngine), the public API
// (attrs `src-name`/`query`/`fields`, the `work-search-*` / `work-command-*`
// events) and the themed result list are all unchanged.
//
// Lazy-loaded from a CDN ESM at runtime (mirrors plot-tier / sqlite-wasm): nothing
// is bundled, no dep is installed. `loadMiniSearch()` is a single-flight import()
// resolving to the MiniSearch constructor, overridable via `window.__WB_MINISEARCH__`
// (tests / offline hosts inject their own). If the import fails (network-blocked,
// the gate's wasm/floor proof), the caller silently falls back to the floor LIKE
// query — the floor is the guaranteed result path.
//
// LOGIC-ONLY: MiniSearch injects NO CSS and renders NO DOM. It returns scored row
// references; the element renders them through its EXISTING themed list. So there
// is no token/scope surface here — this tier never touches styles.

const MINISEARCH_CDN = "https://esm.sh/minisearch@7";

let _msPromise = null;

/**
 * Single-flight lazy import of MiniSearch. Resolves to the MiniSearch constructor.
 * Overridable for tests / offline hosts via `window.__WB_MINISEARCH__` (either the
 * constructor directly, or a `{ default }`/`{ MiniSearch }` module-shaped object).
 * Rejects when the chunk can't load — the caller falls back to the floor LIKE query.
 */
export function loadMiniSearch() {
  const override = typeof window !== "undefined" && window.__WB_MINISEARCH__;
  if (override) return Promise.resolve(normalize(override));
  if (!_msPromise) {
    _msPromise = import(/* @vite-ignore */ MINISEARCH_CDN)
      .then((m) => normalize(m))
      .catch((e) => {
        _msPromise = null; // allow a later retry
        throw e;
      });
  }
  return _msPromise;
}

// Resolve the MiniSearch constructor from whatever shape the import / override
// hands back (the ESM default export, a named export, or the ctor itself).
function normalize(m) {
  if (typeof m === "function") return m;
  return (m && (m.default || m.MiniSearch)) || m;
}

/**
 * Build a MiniSearch index over `rows` (array-of-array, columns named by `columns`)
 * for the searchable `fields`. Each row becomes a document keyed by its row index
 * (`_id`), so a hit maps straight back to the source row — no copy of the row data
 * beyond what the index tokenizes. Pure: returns `{ index, docs }`, mutates nothing.
 *
 * @param MiniSearch  the loaded constructor
 * @param rows        WbQueryResult.rows — array of column-value arrays
 * @param columns     WbQueryResult.columns — column names, index-aligned to a row
 * @param fields      the searchable column names (subset of columns)
 */
export function buildIndex(MiniSearch, rows, columns, fields) {
  const useFields = (fields && fields.length ? fields : columns).filter((f) => columns.includes(f));
  const colIndex = Object.fromEntries(columns.map((c, j) => [c, j]));
  const index = new MiniSearch({
    idField: "_id",
    fields: useFields,
    // store nothing extra — we re-read the row from `rows` by id on a hit.
    searchOptions: {
      prefix: true,            // `ana` matches `analytics` (LIKE can't do trailing)
      fuzzy: 0.2,              // typo tolerance: edit-distance ~= 20% of term length
      combineWith: "OR",       // any token may match (recall ⊇ the AND-of-LIKE floor)
    },
  });
  const docs = rows.map((row, i) => {
    const doc = { _id: i };
    for (const f of useFields) doc[f] = stringify(row[colIndex[f]]);
    return doc;
  });
  index.addAll(docs);
  // Keep the per-row searchable text so search() can run a substring SAFETY-NET:
  // MiniSearch tokenizes (word prefix + fuzzy), so an INFIX substring the floor's
  // LIKE would catch (e.g. "re" inside "Andre") may not be a token hit. To honor
  // the recall-not-regress contract (MiniSearch ⊇ floor LIKE), search() unions the
  // ranked MiniSearch hits with any infix-substring rows they missed.
  const haystacks = rows.map((row) => useFields.map((f) => stringify(row[colIndex[f]])).join("  ").toLowerCase());
  return { index, fields: useFields, haystacks };
}

/**
 * Search `built` (from buildIndex) for `query`, returning a WbQueryResult-shaped
 * subset of the source — the SAME `{ columns, rows, types, rowCount, engine }`
 * contract the floor produces, so the element renders identical chrome. Rows come
 * back in MiniSearch relevance order, capped at `limit`. `engine` is tagged
 * "minisearch" so the element's tier footer reads honestly.
 *
 * @param built    { index } from buildIndex
 * @param source   { columns, rows, types } — the full source result the index was built over
 * @param query    the search term
 * @param limit    max results
 */
export function searchIndex(built, source, query, limit) {
  const q = String(query ?? "").trim();
  const cap = limit > 0 ? limit : 8;
  let picked;
  if (!q) {
    picked = source.rows.slice(0, cap);
  } else {
    const hits = built.index.search(q); // already sorted by descending score
    const seen = new Set();
    const ids = [];
    for (const h of hits) { if (!seen.has(h.id)) { seen.add(h.id); ids.push(h.id); } }
    // recall safety-net: append any INFIX-substring rows MiniSearch's token/prefix
    // match missed, so recall ⊇ the floor LIKE set. These come AFTER the ranked
    // hits (ranking is MiniSearch's; recall is guaranteed) — the floor's `term` is
    // the raw query lower-cased, exactly the `%term%` LIKE substring.
    const needle = q.toLowerCase();
    if (built.haystacks) {
      for (let i = 0; i < built.haystacks.length; i++) {
        if (!seen.has(i) && built.haystacks[i].includes(needle)) { seen.add(i); ids.push(i); }
      }
    }
    picked = [];
    for (const id of ids) {
      const row = source.rows[id];
      if (row) picked.push(row);
      if (picked.length >= cap) break;
    }
  }
  return {
    columns: source.columns,
    rows: picked,
    types: source.types,
    rowCount: picked.length,
    engine: "minisearch",
  };
}

function stringify(v) {
  if (v == null) return "";
  return typeof v === "string" ? v : String(v);
}
