# Agent system — the build plan (the contract)

Built so far: `Nexus.Llm` (OpenRouter/LiteLLM), `Nexus.Agent` (loop, ONE tool: bash), `Agent.Bash`
(wasm CLI kits in wasmtime + VFS), `Agent.Kits` (progressive disclosure), `Agent.Context`
(truncate + window). The agent counted unique lines via `sort|uniq|wc` end to end.

Execute end to end (AUTONOMY MANDATE in AGENTS.md). Each step: `cd nexus && mix compile` clean +
`mix test --exclude compiler` green, commit, push. Live LLM/agent tests are tagged `:llm` (excluded
by default — they cost + need OPENROUTER_API_KEY); prove them manually and keep deterministic
unit tests in the suite.

## The major use case (Phase C is the target)

> A `.work` file authors an agent, runs a flow, and **validates itself** — runs checks. A
> self-validating workbook.

## Phase A — the `agent` unit kind (an agent is a literate FUNCTION)

**Model (non-negotiable):** an agent is a **literate unit in a `.work` file — a function**, a
first-class peer of `resource`/`server`/`rust`/`c`/`zig`. Highly composable, highly malleable. It is
**NOT** the deprecated runtime `<work-agent>` HTML / web-components element — do not parse HTML, do
not reintroduce that. Authored, parsed, compiled, and run the same way every other `.work` unit is.

- `agent :name do … end` — the unit body is the agent's definition (its system prompt / behavior),
  authored literately. Parsed by `Literate` (add `agent` to the code-unit kinds if needed).
- `Nexus.Compile.unit` routes `agent` → a runnable agent def `%{name, system, model}`.
- `Nexus.Agent.from_unit(node)` builds + runs it. An agent is composable: a workbook can hold many
  agents, a `check` invokes one, and (later) one agent can call another as a step. Function-like.
- Proven: author an agent unit in a `.work` file, run a task, get an answer.

## Phase B — the web kit (browsing + scraping)

- Host-brokered `fetch`/`http` builtin in `Agent.Bash` (web access needs host brokering — wasm has
  no sockets). Reuse `Nexus.Dock.fetch` (SSRF-safe: loopback/private blocked, https). curl-class:
  `fetch <url>` → body.
- A `scrape` helper: HTML → readable text (strip tags/scripts), so an agent can read a page. Pure
  Elixir (no new heavy dep) or a small wasm kit.
- Proven: an agent fetches a public URL and answers a question about it.

## Phase C — `check` / self-validating workbooks (THE use case)

- A `check "<description>" do … end` (or `check :name, agent: …, expect: …`) directive in a `.work`
  file: run an agent flow on a task, assert the result satisfies an expectation (a substring, a
  regex, or a second agent/predicate as judge). Returns pass/fail + the transcript.
- `Nexus.Checks.run(root)` runs every check in a workbook → `%{passed, failed, results}`.
- weave renders check results (a green/red list); the server can run them.
- Proven + tested: a `.work` file with an `agent` + a `check` that runs the agent and validates,
  reported pass/fail. This is the deliverable.

## Phase D — context compaction (solid method, beyond windowing)

- When the window would drop messages that carry state, **summarize** the dropped span into a
  compact note (an LLM call or a structured digest) instead of losing it. Keep system + task +
  a running summary + recent turns. Bounded; configurable.
- Proven: a long multi-turn run stays coherent under compaction (a fact from turn 1 survives to turn 30).

## Phase E — kit registry + external kits

- Register external `*.wasm` kits with a manifest (name, summary, commands) for real progressive
  disclosure (not just the filename). A kit's `help` reads its manifest.
- Wire a couple real kits (jq for JSON, ripgrep-class search) if their wasm builds are available;
  else document the registration path. Proven: a registered kit runs through bash.

## Phase F — living example + docs

- A `.work` workbook: an agent that does a real flow (fetch → process → answer) and a `check` that
  validates it. Woven + run. `docs/AGENT.md` — the model, kits, authoring, self-validation.

## Done when

An agent is authorable in a `.work` file, has one tool (bash) over wasm kits incl. web, runs flows,
and a workbook can validate itself with checks — tested, demoed, documented, every suite green, pushed.
