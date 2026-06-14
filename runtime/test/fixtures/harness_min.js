/* Minimal real harness-shaped JS — SLICE 2 (wb-b9xv.10) THESIS exerciser.
 *
 * NOT the full Claude Code; a faithfully-shaped headless harness that holds turn state across the
 * persistent StarlingMonkey instance and drives ONE non-interactive turn end-to-end:
 *   prompt in -> fetch an LLM-shaped endpoint -> the model returns a tool_use -> the harness makes a
 *   BUFFERED tool call over the SLICE-1 exec path (child_process -> brokered wasm CLI) -> feeds the
 *   tool_result back -> a second LLM fetch -> the final text answer out.
 *
 * It exercises require + process + fetch + child_process — the four primitives the slice names. The
 * harness OBJECT lives on globalThis, installed by the boot eval and re-entered by the turn eval, so its
 * conversation state survives BETWEEN evals on the same live heap (the whole point of the persistent
 * instance: __harness, its messages array, and the loaded child_process module all persist).
 *
 * The seam config (LLM url + exec token) is read from globalThis.__wbHarness, injected by the host.
 */
"use strict";

// ── boot: install a resident harness on globalThis (survives across evals on the persistent heap) ──
function installHarness() {
  if (globalThis.__harness) return "already-installed";

  // require + child_process + process: the four named primitives, exercised at boot.
  var cp = require("child_process"); // throws if no exec grant — proves the capability gate
  var seam = globalThis.__wbHarness || {};
  var model = (process && process.env && process.env.WB_MODEL) || "wb-mock-claude";

  var harness = {
    model: model,
    llmUrl: seam.llmUrl,
    token: seam.token,
    messages: [],     // conversation state — persists across evals on the live heap
    turns: 0,
    toolCalls: 0,
    // the one tool the harness exposes to the model; executes via the brokered child_process path.
    tools: [{ name: "run_command", description: "Run a registered command and return its stdout." }],

    // one round-trip to the LLM-shaped endpoint (real fetch -> HTTP -> JSON).
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

    // execute a tool_use block via child_process (buffered, brokered through the SLICE-1 exec path).
    runTool: function (toolUse) {
      var self = this;
      self.toolCalls++;
      var input = toolUse.input || {};
      // child_process.execFileSync resolves to a Promise on the SM lane (await it) -> brokered wasm CLI.
      return cp.execFileSync(input.command, input.args || [], { input: input.stdin || "" })
        .then(function (stdout) {
          var lines = String(stdout).split("\n").filter(function (l) { return l.length; }).length;
          return { tool_use_id: toolUse.id, stdout: stdout, count: String(lines) };
        });
    },

    // ONE non-interactive turn: prompt in -> (model -> tool -> model) -> answer out.
    turn: function (prompt) {
      var self = this;
      self.turns++;
      self.messages.push({ role: "user", content: prompt });

      return self.callModel().then(function (resp1) {
        self.messages.push({ role: "assistant", content: resp1.content });
        var toolUse = (resp1.content || []).filter(function (b) { return b.type === "tool_use"; })[0];

        if (resp1.stop_reason !== "tool_use" || !toolUse) {
          // no tool needed — emit whatever text came back.
          var t0 = (resp1.content || []).filter(function (b) { return b.type === "text"; })[0];
          return (t0 && t0.text) || "";
        }

        return self.runTool(toolUse).then(function (result) {
          // feed the tool_result back as a user-role message (Claude Messages shape).
          self.messages.push({
            role: "user",
            content: [{ type: "tool_result", tool_use_id: result.tool_use_id, content: result.count }]
          });
          return self.callModel().then(function (resp2) {
            self.messages.push({ role: "assistant", content: resp2.content });
            var fin = (resp2.content || []).filter(function (b) { return b.type === "text"; })[0];
            return (fin && fin.text) || "";
          });
        });
      });
    }
  };

  globalThis.__harness = harness;
  return "installed model=" + model + " tools=" + harness.tools.length;
}

installHarness();
