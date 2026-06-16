// git-viz correctness · work-diff semanticDiff — golden table + invariants.
//
// KEY FACT (from the integration directive, Part B): the History backend emits
// the full-file {before, after}, NOT a semantic diff. The entire semantic
// org-block diff lives in work-diff's semanticDiff() — so it is PURE-FRONTEND
// unit-testable with zero backend. This file is the proof: a golden
// (before, after, expected_ops) table covering every op class, plus
// property/conservation invariants over fuzzed org input.
//
// Pure node — `node --test tools/gitviz/work-diff.test.mjs`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { semanticDiff, orgBlocks } from "../../src/elements/git/wb-diff.js";

// The op shape semanticDiff emits, normalized for golden comparison. For "chg"
// blocks we keep the inner line-diff op TYPES (the coalesce signal), not their
// text, so the golden stays legible while still asserting the change is detected.
function shape(ops) {
  return ops.map((o) =>
    o.type === "chg"
      ? { type: "chg", kind: o.kind, key: o.key, lines: o.lines.map((l) => l.type) }
      : { type: o.type, kind: o.kind, key: o.key });
}

// ── GOLDEN TABLE — one case per op class the directive enumerated ─────────────
const GOLDEN = [
  {
    name: "heading edit → del+add of changed para under an unchanged heading",
    a: `* Summary\n  Revenue grew steadily.`,
    b: `* Summary\n  Revenue grew sharply, beating plan.`,
    expect: [
      { type: "eq", kind: "heading", key: "Summary" },
      { type: "del", kind: "para", key: "Revenue grew steadily." },
      { type: "add", kind: "para", key: "Revenue grew sharply, beating plan." },
    ],
  },
  {
    name: "block move — a section relocated reads as del (old slot) + add (new slot)",
    a: `* Intro\n  hi\n* Body\n  text\n* End\n  bye`,
    b: `* Body\n  text\n* Intro\n  hi\n* End\n  bye`,
    // LCS keeps Body+text+End+bye as the common run; the moved Intro+hi reads as
    // a del (from its old leading slot) then add (in its new slot after Body).
    expect: [
      { type: "del", kind: "heading", key: "Intro" },
      { type: "del", kind: "para", key: "hi" },
      { type: "eq", kind: "heading", key: "Body" },
      { type: "eq", kind: "para", key: "text" },
      { type: "add", kind: "heading", key: "Intro" },
      { type: "add", kind: "para", key: "hi" },
      { type: "eq", kind: "heading", key: "End" },
      { type: "eq", kind: "para", key: "bye" },
    ],
  },
  {
    name: "drawer change → :PROPERTIES: drawer del+add coalesces to a chg block",
    a: `* Metrics\n  :PROPERTIES:\n  :revenue: 1.2M\n  :END:`,
    b: `* Metrics\n  :PROPERTIES:\n  :revenue: 1.5M\n  :END:`,
    expect: [
      { type: "eq", kind: "heading", key: "Metrics" },
      // same kind+key (":PROPERTIES:") on both sides → coalesced "chg" with inner line diff
      { type: "chg", kind: "drawer", key: ":PROPERTIES:", lines: ["eq", "del", "add", "eq"] },
    ],
  },
  {
    name: "paragraph add + delete (no shared key) → distinct add and del blocks",
    a: `* Doc\n  keep me\n\n  remove me`,
    b: `* Doc\n  keep me\n\n  brand new`,
    expect: [
      { type: "eq", kind: "heading", key: "Doc" },
      { type: "eq", kind: "para", key: "keep me" },
      { type: "del", kind: "para", key: "remove me" },
      { type: "add", kind: "para", key: "brand new" },
    ],
  },
  {
    name: "intra-block line edit inside a src block → chg with coalesced inner diff",
    a: `#+begin_src sql\n  select sum(amount) from sales;\n#+end_src`,
    b: `#+begin_src sql\n  select sum(amount) from sales where region = 'NA';\n#+end_src`,
    expect: [
      { type: "chg", kind: "block", key: "#+begin_src sql", lines: ["eq", "del", "add", "eq"] },
    ],
  },
  {
    name: "identical input → every block eq",
    a: `* A\n  x\n* B\n  y`,
    b: `* A\n  x\n* B\n  y`,
    expect: [
      { type: "eq", kind: "heading", key: "A" },
      { type: "eq", kind: "para", key: "x" },
      { type: "eq", kind: "heading", key: "B" },
      { type: "eq", kind: "para", key: "y" },
    ],
  },
];

for (const c of GOLDEN) {
  test(`golden · ${c.name}`, () => {
    const got = shape(semanticDiff(c.a, c.b));
    assert.deepEqual(got, c.expect);
  });
}

// ── PROPERTY / CONSERVATION INVARIANTS over fuzzed org ────────────────────────
// A deterministic PRNG so failures reproduce.
function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 0x100000000);
}
function randOrg(rand) {
  const blocks = [];
  const n = 1 + Math.floor(rand() * 6);
  for (let i = 0; i < n; i++) {
    const k = rand();
    if (k < 0.4) blocks.push(`* Section ${Math.floor(rand() * 5)}`);
    else if (k < 0.8) blocks.push(`  paragraph ${Math.floor(rand() * 9)}`);
    else blocks.push(`#+begin_src sh\n  echo ${Math.floor(rand() * 9)}\n#+end_src`);
  }
  return blocks.join("\n");
}

// Reconstruct the "after" source from the ops, to prove no information is lost.
// add/chg blocks carry the b-side; chg's inner line ops reconstruct the new text.
function rebuildAfter(ops) {
  const out = [];
  for (const o of ops) {
    if (o.type === "eq" || o.type === "add") out.push(o.text);
    else if (o.type === "del") continue;
    else if (o.type === "chg") {
      const lines = o.lines.filter((l) => l.type !== "del").map((l) => l.text);
      out.push(lines.join("\n"));
    }
  }
  return out;
}

test("invariant · every op is a known class (eq|del|add|chg), every block accounted for", () => {
  const r = rng(12345);
  for (let i = 0; i < 400; i++) {
    const a = randOrg(r), b = randOrg(r);
    const ops = semanticDiff(a, b);
    const aBlocks = orgBlocks(a).length, bBlocks = orgBlocks(b).length;
    let aSeen = 0, bSeen = 0;
    for (const o of ops) {
      assert.ok(["eq", "del", "add", "chg"].includes(o.type), `bad op type ${o.type}`);
      if (o.type === "eq") { aSeen++; bSeen++; }
      else if (o.type === "del") aSeen++;
      else if (o.type === "add") bSeen++;
      else if (o.type === "chg") { aSeen++; bSeen++; } // a coalesced del+add
    }
    // conservation: every before-block is consumed (eq|del|chg), every after-block
    // produced (eq|add|chg) — no silent drop or fabrication.
    assert.equal(aSeen, aBlocks, `before-block count mismatch (seed run ${i})`);
    assert.equal(bSeen, bBlocks, `after-block count mismatch (seed run ${i})`);
  }
});

test("invariant · diff(x,x) is all-eq for any org input", () => {
  const r = rng(999);
  for (let i = 0; i < 200; i++) {
    const x = randOrg(r);
    const ops = semanticDiff(x, x);
    assert.ok(ops.every((o) => o.type === "eq"), "diff(x,x) produced a non-eq op");
    assert.equal(ops.length, orgBlocks(x).length);
  }
});

test("invariant · applying the ops reconstructs `after`", () => {
  const r = rng(424242);
  for (let i = 0; i < 300; i++) {
    const a = randOrg(r), b = randOrg(r);
    const ops = semanticDiff(a, b);
    const rebuilt = rebuildAfter(ops).join("\n");
    // compare at the block level (whitespace between blocks is the segmenter's,
    // not the diff's, concern) — every after-block must reappear in order.
    const want = orgBlocks(b).map((x) => x.text);
    const got = orgBlocks(rebuilt).map((x) => x.text);
    assert.deepEqual(got, want, `reconstruction mismatch (seed run ${i})\nA=${JSON.stringify(a)}\nB=${JSON.stringify(b)}`);
  }
});
