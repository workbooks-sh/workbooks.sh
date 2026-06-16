// gate · fixtures — per-element mount config.
//
// The CEM (custom-elements.json) is the element registry; this supplies the
// minimal props/innerHTML that make each element render something paintable, so
// the token / scope / visual gates have real chrome to measure. An element with
// no override here mounts bare (its empty-state chrome is enough for the token +
// scope gates). Keep fixtures DATA-only and theme-agnostic — never hardcode a
// color (that would defeat the token gates).
//
// A fixture is { attrs?:{}, html?:"" }. `variants` (optional) lists extra attr
// combinations the visual gate renders as separate baseline shots (key variants).

const ORG_A = `* Summary
  Revenue grew steadily.
* Metrics
  :PROPERTIES:
  :revenue: 1.2M
  :END:`;
const ORG_B = `* Summary
  Revenue grew sharply, beating plan.
* Metrics
  :PROPERTIES:
  :revenue: 1.5M
  :END:
* Outlook
  Next quarter looks strong.`;

const HISTORY_ITEMS = JSON.stringify([
  { id: "f1a2b3c4", when: 1718000000, author_type: "agent", author_name: "analyst-agent", title: "Refresh metrics" },
  { id: "9d8e7c6b", when: 1717900000, author_type: "human", author_name: "shane", title: "Initial draft" },
]);

const ROWS = JSON.stringify([
  { region: "NA", revenue: 1200 },
  { region: "EU", revenue: 980 },
  { region: "APAC", revenue: 1430 },
]);

// work-search · a frozen golden corpus + query. The parity gate's oracle is the
// FLOOR LIKE result set over this exact corpus+query; the candidate is the
// MiniSearch result set. Recall must NOT regress (MiniSearch ⊇ floor LIKE). The
// query "re" is a substring the floor LIKE finds in several titles; MiniSearch
// (prefix + OR) must surface at least the same rows. Token-only (no color).
export const SEARCH_CORPUS = JSON.stringify([
  { name: "Revenue report", team: "Finance" },
  { name: "Restore snapshot", team: "Platform" },
  { name: "Region rollout", team: "Growth" },
  { name: "Analytics dashboard", team: "Data" },
  { name: "Release notes", team: "Docs" },
  { name: "Onboarding flow", team: "Product" },
]);
export const SEARCH_QUERY = "re";

// work-map · a frozen golden point set. The parity gate's oracle is the FLOOR's
// projected feature model (`_features`: kind/i/lat/lon/v); the candidate is the
// feature set MapLibre BOUND (the GeoJSON the powered tier handed the map's
// `wb-data` source). MapLibre must receive the SAME features — same count, same
// per-feature index→coord→value mapping — proving the powered tier binds the
// identical engine result, not the same pixels. Token-only (no color).
export const MAP_ROWS = JSON.stringify([
  { city: "Oslo", lat: 59.91, lon: 10.75, pop: 700 },
  { city: "Tokyo", lat: 35.68, lon: 139.69, pop: 1400 },
  { city: "Lima", lat: -12.05, lon: -77.04, pop: 950 },
  { city: "Cairo", lat: 30.04, lon: 31.24, pop: 1100 },
]);

// work-editor · a frozen golden doc + language. The parity gate's oracle is the
// FLOOR's value/change-contract (the textarea value + the `work-code-change`
// detail.value on edit); the candidate is the CodeMirror doc + its change event
// for the SAME edit. The powered tier must expose the IDENTICAL value contract
// (getValue/setValue/work-code-change), not the same pixels. Token-only.
export const EDITOR_DOC = `const greet = (name) => {\n  // say hello\n  return "hi " + name;\n};`;
export const EDITOR_EDIT = `${EDITOR_DOC}\nconst n = 42;`;

// work-doc · a representative document — the docs-domain substrate the composition
// model centers on (preview ≡ source; the same bytes render). This exercises the
// standalone renderer's full surface DETERMINISTICALLY (no engine round-trip, so
// the visual baseline is stable offline): headings, prose, an org TODO pill, a
// checkbox list, a markdown table, and a fenced code block. It is theme-agnostic
// (no hardcoded color) so the token-flip gate measures real prose chrome. A live
// compute cell (```chart / ```sql) is intentionally NOT in the baseline fixture —
// cells round-trip an engine that is CDN-blocked offline, which would make the
// shot nondeterministic; the live-cell path is proven by work-doc-cell + the
// browser demo. This is the floor a docked Host upgrades through the OQL kernel.
const DOC_SRC = `# Quarterly Review

Revenue grew steadily across every region. The document **is** its source —
the same bytes an agent or cursor edits are what you see rendered.

## Action items

- [x] Refresh the metrics table
- [ ] Draft the outlook section

TODO Follow up with the growth team on APAC

## Regional revenue

| Region | Revenue |
| ------ | ------- |
| NA     | 1200    |
| EU     | 980     |
| APAC   | 1430    |

\`\`\`
export const total = 1200 + 980 + 1430;
\`\`\`
`;

export const FIXTURES = {
  "work-button": { html: "Click me", variants: [{ variant: "soft" }, { variant: "outline", tone: "err" }] },
  "work-diff": { attrs: { a: ORG_A, b: ORG_B, mode: "split" }, variants: [{ mode: "inline" }] },
  "work-history-graph": { attrs: { items: HISTORY_ITEMS } },
  "work-chart": { attrs: { type: "bar", x: "region", y: "revenue", rows: ROWS }, variants: [{ type: "line" }] },
  "work-spark": { attrs: { values: "3,5,2,8,6,9,4" } },
  "work-metric": { attrs: { label: "Revenue", value: "1.43M", delta: "+12%" } },
  "work-table": { attrs: { rows: ROWS } },
  "work-message": { attrs: { role: "assistant", name: "agent", text: "Here is the result." } },
  "work-composer": { attrs: { placeholder: "Ask anything…" } },
  "work-gen-block": { attrs: { type: "action", label: "Run", action: "run" } },
  "work-field": { attrs: { label: "Email", placeholder: "you@co" } },
  "work-search": { attrs: { placeholder: "Search…", rows: SEARCH_CORPUS, fields: "name,team", value: SEARCH_QUERY, "open-on-focus": true } },
  "work-map": { attrs: { rows: MAP_ROWS, lat: "lat", lon: "lon", value: "pop", label: "city", mode: "points" } },
  "work-editor": { attrs: { language: "js", value: EDITOR_DOC } },
  "work-user": { attrs: { name: "Shane", variant: "compact" } },
  "work-auth": { attrs: { mode: "password" } },
  "work-file": { attrs: { name: "report.org", size: "12 KB" } },
  "work-metric-card": {},
  "work-doc": { html: DOC_SRC },
  // 3d · the gate runs OFFLINE (the model-viewer CDN ESM is unreachable / not
  // injected), so this deterministically renders the THEMED FLOOR placeholder —
  // the stable fixture the directive calls for. (The real <model-viewer> render is
  // proven in the browser demo with __WB_MODELVIEWER__ false.) A `name` gives the
  // placeholder a label to paint; `src` proves the floor still shows when the
  // engine can't load (graceful degrade), exercising the same gate-c posture.
  "work-model": { attrs: { name: "Astronaut", src: "astronaut.glb", "camera-controls": true }, variants: [{ variant: "soft" }] },
  // presentation · a deck IS a wavelet timeline; mount one with a title + a content
  // slide so the token/visual gates measure real chrome (the controls + a band). The
  // slide is a child element, so it gets its own bare fixture entry for completeness.
  "work-deck": { attrs: { controls: true, aspect: "16:9" }, html: '<work-slide band="title"><h1>Deck</h1><p>One substrate, many domains.</p></work-slide><work-slide band="content" align="start"><h2>Highlights</h2><ul><li>Live charts on slides</li><li>Export to video</li></ul></work-slide>' },
  "work-slide": { attrs: { band: "title", active: true }, html: "<h1>Slide</h1><p>A keyframe band.</p>" },
};

/** Build the mount spec for a tag, merging CEM attrs with the fixture. */
export function fixtureFor(tag) {
  return FIXTURES[tag] || {};
}
