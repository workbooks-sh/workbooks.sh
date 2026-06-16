// git-viz correctness · work-history-graph — DOM rendering, via headless Chromium.
//
// The History backend (runtime/host/history.ex) returns, newest-first:
//   [ %{ id, when, author_type: "human"|"agent", author_name, title } ]
// This freezes a fixture in that exact documented shape, feeds it to the element's
// `.items` property, and asserts via the real shadow DOM that the element renders
// it faithfully — the rendering is the correctness surface (unlike work-diff, the
// element does no computation here; it must just not LIE about the backend data):
//   1. node order === fixture order (newest-first preserved, no re-sort)
//   2. N items → exactly N nodes (no silent drop / coalesce)
//   3. human/agent attribution is 1:1 with the badge (no misattribution)
//   4. linear input → linear render (no fictional merge branches drawn)
//
// Reuses the gate's offline server + harness page (one Playwright process).
// Run: `node tools/gitviz/work-history-graph.test.mjs` (exit 0 = pass).

import { chromium } from "playwright";
import { startServer } from "../gate/server.js";

// ── frozen fixture — exactly history.ex's Change shape, newest-first ──────────
const ITEMS = [
  { id: "f1a2b3c4d5", when: 1718500000, author_type: "agent", author_name: "analyst-agent", title: "Add Outlook section, refresh metrics" },
  { id: "9d8e7c6b5a", when: 1718490000, author_type: "human", author_name: "shane", title: "Edit summary copy" },
  { id: "1122334455", when: 1718400000, author_type: "agent", author_name: "scaffold-agent", title: "Scaffold report from template" },
  { id: "aabbccddee", when: 1718300000, author_type: "human", author_name: "dana", title: "Initial quarterly report draft" },
];

let failures = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`  ✔ ${name}`); }
  else { console.log(`  ✘ ${name}${detail ? " — " + detail : ""}`); failures++; }
}

const { url, close } = await startServer();
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));
await page.goto(`${url}/__gate/page.html`, { waitUntil: "load" });
await page.waitForFunction(() => window.__workponentsLoaded === true, { timeout: 15000 });
await page.waitForFunction(() => window.customElements.get("work-history-graph") != null, { timeout: 15000 });

// mount + assign the items PROPERTY (not the attribute) — the host wiring path
await page.evaluate((items) => {
  const el = document.createElement("work-history-graph");
  document.querySelector("#stage").innerHTML = "";
  document.querySelector("#stage").appendChild(el);
  el.items = items; // property assignment, as a host would do
}, ITEMS);
await page.waitForFunction(() => {
  const el = document.querySelector("work-history-graph");
  return el && el.shadowRoot && el.shadowRoot.querySelectorAll("li").length > 0;
}, { timeout: 5000 });

// read back the rendered node model from the shadow DOM
const rendered = await page.evaluate(() => {
  const el = document.querySelector("work-history-graph");
  const lis = [...el.shadowRoot.querySelectorAll("li")];
  return lis.map((li) => ({
    id: li.getAttribute("data-id"),
    author: li.getAttribute("data-author"),
    title: li.querySelector(".title")?.textContent?.trim(),
    badgeClass: li.querySelector(".badge")?.classList.contains("agent") ? "agent"
      : li.querySelector(".badge")?.classList.contains("human") ? "human" : null,
    badgeName: li.querySelector(".badge")?.textContent?.trim(),
    railNodes: li.querySelectorAll(".rail .node").length,
  }));
});

await browser.close();
await close();

console.log("work-history-graph — DOM correctness\n");

// 2. N items → N nodes (no silent drop)
check("N items → N rendered nodes (no drop/coalesce)", rendered.length === ITEMS.length,
  `got ${rendered.length} of ${ITEMS.length}`);

// 1. node order === fixture order (newest-first preserved)
const orderOk = rendered.every((r, i) => r.id === String(ITEMS[i].id).slice(0, 10) || r.id === ITEMS[i].id);
check("node order === fixture order (newest-first, no re-sort)", orderOk,
  `rendered ids: ${rendered.map((r) => r.id).join(",")}`);

// 3. human/agent attribution 1:1 with the badge
let attrOk = true, attrDetail = "";
for (let i = 0; i < Math.min(rendered.length, ITEMS.length); i++) {
  const want = ITEMS[i].author_type;
  if (rendered[i].author !== want || rendered[i].badgeClass !== want) {
    attrOk = false; attrDetail = `idx ${i}: want ${want}, got data-author=${rendered[i].author} badge=${rendered[i].badgeClass}`; break;
  }
  if (!rendered[i].badgeName?.includes(ITEMS[i].author_name)) {
    attrOk = false; attrDetail = `idx ${i}: badge name "${rendered[i].badgeName}" missing "${ITEMS[i].author_name}"`; break;
  }
}
check("human/agent attribution is 1:1 with the badge (class + name)", attrOk, attrDetail);

// 4. linear input → linear render: exactly one rail node per row, no extra
// branch/merge nodes drawn (a fictional merge would render >1 node on a row).
const linearOk = rendered.every((r) => r.railNodes === 1);
check("linear input → linear render (one rail node per row, no fictional merges)", linearOk,
  `rail-node counts: ${rendered.map((r) => r.railNodes).join(",")}`);

check("no page errors during render", pageErrors.length === 0, pageErrors.join(" | "));

console.log(`\n${failures === 0 ? "PASS" : "FAIL"} — ${rendered.length} nodes asserted, ${failures} failure(s).`);
process.exit(failures === 0 ? 0 : 1);
