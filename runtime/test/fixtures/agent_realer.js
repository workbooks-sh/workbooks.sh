/* A REAL-ER headless coding-agent shape — wb-b9xv, persistent-StarlingMonkey lane.
 *
 * Goes past harness_min.js: a stateful agent that lives on the resident SM heap and exercises the FULL
 * now-supported surface across a turn — confined fs (read+write its workdir), a STREAMING tool
 * (child_process.spawn → incremental stdout 'data' events), the LLM-shaped endpoint, AND an async
 * multi-step turn — while respecting the ONE hard runtime ceiling the slice MEASURED:
 *
 *   On the persistent instance, every host-seam op (fs read/write, LLM fetch, exec) is a GUEST fetch().
 *   The vendored wasmtime/Wasmex wasi:http component reliably re-enters run() only after entries that did
 *   AT MOST ONE guest fetch. An entry that stacks 2+ awaited fetches returns its value but INTERMITTENTLY
 *   leaves the component non-re-enterable (the next run() traps "cannot enter component instance").
 *
 * So this agent is a STEP MACHINE with strict ONE-FETCH-PER-ENTRY discipline: each phase performs at most a
 * single guest fetch, and ALL state (conversation, scratchpad mirror, phase cursor) persists on the live
 * heap BETWEEN entries — which is the entire point of the persistent instance. The host drives it by calling
 * agent.step() repeatedly until done; re-entry stays safe because no LLM/fs/exec phase issues >1 fetch.
 *
 * The streaming tool is the explicit exception: child_process.spawn long-polls MANY fetches in one entry —
 * it DELIVERS its incremental chunks correctly, but consumes the instance's re-enterability. So it is the
 * TERMINAL phase: the host runs it last and recycle()s the instance afterward (cost #2 — poison recovery).
 *
 * Surface exercised, by the slice's letters:
 *   (a) fs    — require('node:fs')/'fs/promises' writes + reads files CONFINED to the granted workdir
 *   (b) stream— child_process.spawn drives the streaming protocol; the agent consumes INCREMENTAL chunks
 *   (c) llm   — fetch() the LLM-shaped endpoint (Claude-Messages mock on the pinned sentinel)
 *   (d) async — a multi-step turn; heap state survives across run() entries on ONE live instance
 *
 * Seam: globalThis.__wbHarness = { llmUrl, token } (host-injected). require('child_process'),
 * require('node:fs'), process come from the resident Node platform installed at boot.
 */
"use strict";

function installAgent() {
  if (globalThis.__agent) return "already-installed";

  var cp = require("child_process");      // throws without an exec grant — the capability gate
  var fs = require("node:fs");            // throws without an fs grant — the workdir-confinement gate
  var seam = globalThis.__wbHarness || {};
  var model = (process && process.env && process.env.WB_MODEL) || "wb-mock-claude";

  var agent = {
    model: model,
    llmUrl: seam.llmUrl,
    token: seam.token,
    messages: [],           // conversation state — persists across run() entries on the live heap
    files: [],              // scratchpad mirror: names we've written (proof state survived across entries)
    streamChunks: 0,        // INCREMENTAL stdout chunks the streaming tool delivered (>1 == real streaming)
    streamBytes: 0,
    phase: "plan",          // the step machine's cursor — persists between entries
    toolCalls: 0,
    answer: null,
    log: [],

    tools: [{ name: "run_command", description: "Run a registered command; return its stdout line count." }],

    // (c) ONE fetch to the LLM-shaped endpoint per call — each lives in its own run() entry.
    callModel: function () {
      var self = this;
      return fetch(self.llmUrl, {
        method: "POST",
        headers: { "content-type": "application/json", "x-wb-exec": self.token },
        body: JSON.stringify({ model: self.model, messages: self.messages, tools: self.tools })
      }).then(function (r) {
        if (!r.ok) throw new Error("LLM endpoint refused: " + r.status);
        return r.json();
      });
    },

    // ── the step machine: each call is ONE run() entry, ≤1 guest fetch, advancing exactly one round-trip ──
    // Returns a small status object the host inspects: { step, done, ... }. The host loops step() until done.
    step: function (prompt) {
      var self = this;

      switch (self.phase) {
        // PHASE plan — (a) fs WRITE only (one fetch): record the plan in the confined workdir.
        case "plan":
          self.messages.push({ role: "user", content: prompt });
          return fs.promises.writeFile("PLAN.md", "# plan\n- " + prompt + "\n").then(function () {
            self.files.push("PLAN.md");
            self.log.push("wrote PLAN.md");
            self.phase = "readback";
            return { step: "fs.write", done: false };
          });

        // PHASE readback — (a) fs READ only (one fetch): read the plan back, proving the round-trip.
        case "readback":
          return fs.promises.readFile("PLAN.md", "utf8").then(function (back) {
            self.log.push("read PLAN.md (" + back.length + "b)");
            self.phase = "llm1";
            return { step: "fs.read", done: false, planBytes: back.length };
          });

        // PHASE llm1 — (c) first model call (one fetch). Mock returns a tool_use (count 'needle' matches).
        case "llm1":
          return self.callModel().then(function (resp) {
            self.messages.push({ role: "assistant", content: resp.content });
            self.pendingToolUse = (resp.content || []).filter(function (b) { return b.type === "tool_use"; })[0];
            self.phase = self.pendingToolUse ? "tool" : "writeans";
            return { step: "llm1", done: false, stopReason: resp.stop_reason };
          });

        // PHASE tool — (c) brokered BUFFERED exec (one fetch): run the model's tool_use, feed result back.
        case "tool":
          var t = self.pendingToolUse, input = t.input || {};
          self.toolCalls++;
          return cp.execFileSync(input.command, input.args || [], { input: input.stdin || "" }).then(function (out) {
            var count = String(out).split("\n").filter(function (l) { return l.length; }).length;
            self.messages.push({ role: "user", content: [{ type: "tool_result", tool_use_id: t.id, content: String(count) }] });
            self.log.push("ran tool " + input.command + " -> " + count + " lines");
            self.phase = "llm2";
            return { step: "tool", done: false, count: count };
          });

        // PHASE llm2 — (c) second model call (one fetch). tool_result present => final text answer.
        case "llm2":
          return self.callModel().then(function (resp) {
            self.messages.push({ role: "assistant", content: resp.content });
            var fin = (resp.content || []).filter(function (b) { return b.type === "text"; })[0];
            self.answer = (fin && fin.text) || "";
            self.phase = "writeans";
            return { step: "llm2", done: false };
          });

        // PHASE writeans — (a) fs WRITE only (one fetch): persist the answer into the workdir.
        case "writeans":
          return fs.promises.writeFile("ANSWER.txt", self.answer || "").then(function () {
            self.files.push("ANSWER.txt");
            self.log.push("wrote ANSWER.txt");
            self.phase = "stream";
            return { step: "fs.writeans", done: false, answer: self.answer };
          });

        // PHASE stream — (b) the streaming capstone: spawn a long-running registered CLI and CONSUME its
        // INCREMENTAL stdout (many 'data' events). This entry long-polls MANY fetches, so it is TERMINAL: it
        // returns its streaming proof, but the host must recycle() the instance before any further re-entry.
        case "stream":
          return new Promise(function (resolve, reject) {
            var child = cp.spawn("coreutils", ["seq", "200000"]);
            var buf = "";
            child.stdout.on("data", function (chunk) { self.streamChunks++; self.streamBytes += chunk.length; buf += chunk; });
            child.on("exit", function (code) {
              self.toolCalls++;
              self.phase = "done";
              self.log.push("streamed " + self.streamChunks + " chunks / " + self.streamBytes + "b");
              resolve({ step: "stream", done: true, terminal: true, chunks: self.streamChunks, bytes: self.streamBytes,
                        lastLine: buf.trim().split("\n").pop(), code: code, toolCalls: self.toolCalls, answer: self.answer });
            });
            child.on("error", function (e) { reject(e); });
          });

        default:
          return Promise.resolve({ step: self.phase, done: true, answer: self.answer });
      }
    }
  };

  globalThis.__agent = agent;
  return "installed model=" + model + " tools=" + agent.tools.length;
}

installAgent();
