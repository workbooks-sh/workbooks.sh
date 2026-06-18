# Agents

An agent is a **literate function** authored in a `.work` file — a first-class peer of `resource` /
`server` / `rust`. Highly composable, highly malleable. (It is **not** the deprecated runtime
`<work-agent>` HTML element — that model is gone.)

## The model

- **One tool: `bash`.** An agent accomplishes everything by running command lines in `bash`. There
  are no discrete "tools".
- **Kits are wrapped CLIs.** A kit is a `wasm32-wasi` command run in **wasmtime** against the agent's
  **VFS** (`/work`). `coreutils` (ls/cat/sort/uniq/wc/grep-less base) is the core kit; `web`
  (`fetch`/`scrape`) is host-brokered. More kits drop into `kits/`.
- **Progressive disclosure.** The system prompt lists kit names + one-liners; the agent runs
  `help <kit>` to see a kit's commands only when it needs them — context stays small.
- **Context management.** `Nexus.Agent.Context` truncates huge bash output and slides a window;
  `compact: true` summarizes dropped spans (an early fact survives a long run).
- **Sandboxed.** The agent sees only `/work`; commands run as wasm, never native; `web` is
  SSRF-brokered. Bounded by wall-clock, not a turn cap.

## Authoring an agent

```
agent :analyst do
  You are a terse data analyst. You have one tool, bash, with the coreutils and web kits. Always
  COMPUTE with bash against /work — never guess. Reply with exactly the requested format.
end
```

Run it from Elixir:

```elixir
node = "agent :analyst do … end" |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))
{:ok, %{answer: a}} = Nexus.Agent.run_unit(node, "Count unique lines in /work/x.txt, reply UNIQUE=<n>",
                                            seed: %{"x.txt" => "a\nb\na\n"})
```

Or compose directly: `Nexus.Agent.run(system: "…", task: "…", seed: %{…}, compact: true)`.

## Self-validating workbooks (the major use case)

A `.work` file authors an agent **and** `check` directives that run it and assert the result — the
workbook validates itself:

```
check :unique_count do
  agent analyst                                              # which agent to run
  task Count the UNIQUE lines in /work/log.txt, reply UNIQUE=<n>
  seed log.txt = alpha\nbeta\nalpha\ngamma\nbeta\nalpha\n    # seed the VFS
  expect UNIQUE=3                                            # substring (or /regex/) the answer must contain
end
```

Run the validation:

```
mix nexus.check examples/agent-demo
# [PASS] unique_count — expect UNIQUE=3 — got: UNIQUE=3
# [PASS] total_lines  — expect TOTAL=6  — got: TOTAL=6
# 2 passed, 0 failed         (exits non-zero if any fail — CI-friendly)
```

`Nexus.Checks.run(root)` returns `%{passed, failed, results}`; `Nexus.Checks.render_html/1` renders
a green/red report for weave to embed. See `examples/agent-demo/` for a working, self-validating
workbook.

## LLM provider

`Nexus.Llm` speaks the OpenAI chat API; **OpenRouter** by default. Point it at **LiteLLM** (or any
OpenAI-compatible proxy / self-hosted server) to route across providers behind one endpoint:

```elixir
config :nexus, Nexus.Llm,
  base_url: "http://localhost:4000/v1/chat/completions",  # a LiteLLM proxy
  model: "openai/gpt-4o-mini",
  api_key_env: "LITELLM_API_KEY"
```

The key lives host-side (env), never in a workbook.

## Files

- `Nexus.Llm` — the chat client (multi-turn, tools, configurable base_url).
- `Nexus.Agent` — the loop (one tool: bash); `def_from_unit`/`run_unit` for `agent` units.
- `Nexus.Agent.Bash` — the tool: wasm kits in wasmtime against the VFS, pipes, `kits`/`help`/`fetch`/`scrape`.
- `Nexus.Agent.Kits` — the kit registry + progressive disclosure.
- `Nexus.Agent.Vfs` — the `/work` workspace.
- `Nexus.Agent.Context` — truncation, window, compaction.
- `Nexus.Checks` — `check` units → run agents → assert; `mix nexus.check`.
