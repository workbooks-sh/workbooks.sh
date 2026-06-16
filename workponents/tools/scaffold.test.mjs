// Eval for `work component new` — proves the scaffolder produces a token-clean,
// well-formed, correctly-named work-* element WITHOUT polluting the tree (it asserts
// the pure exports). The end-to-end registration (CEM regen, barrel, gate) is covered
// by the existing design-lint + the CI 5-gate, which validate every element in src.
import { test } from "node:test";
import assert from "node:assert/strict";
import { elementSource, derive } from "./scaffold.mjs";

test("derive: name/domain → tag, class, import path", () => {
  const d = derive("status-card", "data-viz", ["data-viz", "docs"]);
  assert.equal(d.tag, "work-status-card");
  assert.equal(d.cls, "WbStatusCard");
  assert.equal(d.importPath, "../../core/element.js");
  // a `work-` prefix on input is tolerated (tag is always work-<name>)
  assert.equal(derive("work-foo", "docs", ["docs"]).tag, "work-foo");
  // core domain imports the base from one level up
  assert.equal(derive("foo", "core", []).importPath, "./core/element.js");
});

test("derive: rejects bad names + unknown domains", () => {
  assert.throws(() => derive("Bad Name", null, []), /kebab-case/);
  assert.throws(() => derive("ok", "nope", ["data-viz"]), /unknown domain/);
});

test("scaffolded element is token-only (no literal colors) — passes the token gate", () => {
  const src = elementSource({ tag: "work-probe", cls: "WbProbe", name: "probe", importPath: "../../core/element.js" });
  assert.equal(/#[0-9a-fA-F]{3,8}\b/.test(src), false, "no hex literals");
  assert.equal(/\b(rgba?|hsla?)\(/.test(src), false, "no rgb/hsl literals");
  assert.match(src, /var\(--work-/, "themes via --work-* tokens");
});

test("scaffolded element is well-formed: extends WbElement + registers the tag", () => {
  const src = elementSource({ tag: "work-probe", cls: "WbProbe", name: "probe", importPath: "../../core/element.js" });
  assert.match(src, /import \{ WbElement, html, css, define \}/);
  assert.match(src, /export class WbProbe extends WbElement/);
  assert.match(src, /define\("work-probe", WbProbe\)/);
  assert.match(src, /render\(\)/);
});
