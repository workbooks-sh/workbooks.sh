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
  "work-user": { attrs: { name: "Shane", variant: "compact" } },
  "work-auth": { attrs: { mode: "password" } },
  "work-file": { attrs: { name: "report.org", size: "12 KB" } },
  "work-metric-card": {},
};

/** Build the mount spec for a tag, merging CEM attrs with the fixture. */
export function fixtureFor(tag) {
  return FIXTURES[tag] || {};
}
