// wb-pkh.9 — validate the JS Dock SDK: pure helpers + the bind() cap wrappers over
// stub jco imports (same shape jco generates), mirroring the Rust bind_compile test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { out, rows, page, parseMany, checkError, DockError, bind } from "../index.js";

test("out builds clean JSON (escapes quotes, no lossy hack)", () => {
  assert.equal(out({ asked: 'hi "there"', n: 3 }), '{"asked":"hi \\"there\\"","n":3}');
});

test("rows decodes; error envelope throws", () => {
  assert.deepEqual(rows('[{"n":1},{"n":2}]'), [{ n: 1 }, { n: 2 }]);
  assert.throws(() => rows('{"error":"boom"}'), DockError);
});

test("page decodes + keeps extra fields; error envelope throws", () => {
  const p = page('{"url":"u","title":"t","lang":"en"}');
  assert.equal(p.url, "u");
  assert.equal(p.lang, "en");
  assert.throws(() => page('{"error":"nope"}'), DockError);
});

test("parseMany splits ok/error per worker, in order", () => {
  const r = parseMany('[{"ok":"cba"},{"error":"boom"},{"ok":"zyx"}]');
  assert.deepEqual(r, [{ ok: "cba" }, { error: "boom" }, { ok: "zyx" }]);
});

test("checkError only fires on a lone {error} envelope", () => {
  assert.doesNotThrow(() => checkError('{"error":"x","other":1}')); // not a lone envelope
  assert.doesNotThrow(() => checkError("not json"));
  assert.throws(() => checkError('{"error":"x"}'), DockError);
});

// Stub jco bindings (the shape jco componentize generates) — validates bind().
const imports = {
  llmComplete: () => "the-reply",
  vfsQuery: () => '[{"n":1},{"n":2}]',
  browseFetch: () => '{"url":"https://x","title":"X"}',
  runCommand: () => "ran-ok",
  runCommandMany: () => '[{"ok":"cba"},{"error":"boom"}]',
};

test("bind() wires all cap wrappers and they work", () => {
  const dock = bind(imports);
  assert.equal(dock.llm.ask("hi"), "the-reply");
  assert.deepEqual(dock.vfs.query("select n"), [{ n: 1 }, { n: 2 }]);
  assert.equal(dock.browse.fetch("https://x").url, "https://x");
  assert.equal(dock.command.run("jq", "{}", [".x"]), "ran-ok");
  const many = dock.parallel.map("rev", ["abc", "xyz"]);
  assert.deepEqual(many, [{ ok: "cba" }, { error: "boom" }]);
});

test("bind() is cap-scoped — only provided imports resolve", () => {
  const dock = bind({ llmComplete: () => "x" });
  assert.equal(typeof dock.llm, "object");
  assert.equal(dock.vfs, undefined);
  assert.equal(dock.parallel, undefined);
});

test("a cap wrapper surfaces a host error envelope as DockError", () => {
  const dock = bind({ llmComplete: () => '{"error":"rate-limited"}' });
  assert.throws(() => dock.llm.ask("hi"), DockError);
});
