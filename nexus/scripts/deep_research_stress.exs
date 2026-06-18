# Deep-research concurrency stress test — REAL nexus runtime.
#
# Fans out N concurrent research agents over OpenRouter (qwen/qwen3.7-plus:online).
# Each agent runs a 3-round deep-research loop:
#   R1 search  — :online web search on its subtopic (live URLs)
#   R2 deepen  — :online follow-up grounded in R1 findings
#   R3 synth   — cited brief from the gathered material (no search; cheaper)
#
# Ramps concurrency to find the ceiling: where do latency / errors / rate-limits bite?
#
#   cd nexus && mix run scripts/deep_research_stress.exs            # default ramp
#   WAVES=8,16,32 MODEL=qwen/qwen3.7-plus mix run scripts/deep_research_stress.exs

defmodule DeepResearchStress do
  @search_model System.get_env("MODEL", "qwen/qwen3.7-plus") <> ":online"
  @synth_model  System.get_env("MODEL", "qwen/qwen3.7-plus")
  @maxtok 700

  @topics [
    "in-wasm WebAssembly compiler toolchains for Rust without wasi-sdk",
    "BEAM/Elixir process concurrency limits on a single node in 2026",
    "state of headless browser automation inside WebAssembly sandboxes",
    "OpenRouter pricing and rate limits for concurrent API requests",
    "Stylo and Servo CSS layout engines reused outside Firefox",
    "content-addressed build caches in distributed compiler systems",
    "krunvm and microVM cold-start performance on macOS",
    "vector database options with pgvector vs dedicated engines 2026",
    "WorkOS AuthKit vs Clerk for B2B SaaS authentication",
    "Cloudflare R2 egress-free object storage economics",
    "litestream SQLite replication for single-node durability",
    "wasmtime vs wasmer for production server-side WASM in 2026",
    "Polars vs DuckDB for in-process analytical queries",
    "Lit web components versus React for framework-agnostic UI kits",
    "Fly.io Machines scale-to-zero latency and billing model",
    "Candle Rust ML inference framework adoption and benchmarks"
  ]

  def call(model, messages) do
    t0 = System.monotonic_time(:millisecond)
    case Nexus.Llm.complete(messages, model: model, max_tokens: @maxtok, timeout: 240_000) do
      {:ok, turn} ->
        dt = System.monotonic_time(:millisecond) - t0
        u = turn.usage || %{}
        {:ok, turn.content, %{ms: dt, tokens: u["total_tokens"] || 0, cost: u["cost"] || 0.0}}
      {:error, e} ->
        dt = System.monotonic_time(:millisecond) - t0
        {:error, e, %{ms: dt, tokens: 0, cost: 0.0}}
    end
  end

  # one agent = 3 rounds. returns {:ok, meta} | {:error, stage, meta}
  def agent(topic) do
    acc = %{ms: 0, tokens: 0, cost: 0.0, rounds: 0}

    with {:ok, r1, m1} <-
           call(@search_model, [%{role: "user",
             content: "Research this for a technical brief. Find current facts and cite source URLs:\n#{topic}"}]),
         acc = merge(acc, m1),
         {:ok, r2, m2} <-
           call(@search_model, [
             %{role: "user", content: "Topic: #{topic}"},
             %{role: "assistant", content: r1},
             %{role: "user", content: "Go deeper: surface the most important number, tradeoff, or recent change I missed. Cite URLs."}]),
         acc = merge(acc, m2),
         {:ok, _r3, m3} <-
           call(@synth_model, [
             %{role: "user", content: "Synthesize a 5-bullet cited research brief on '#{topic}' from these notes:\n\n## Notes 1\n#{r1}\n\n## Notes 2\n#{r2}"}]) do
      {:ok, merge(acc, m3)}
    else
      {:error, e, m} -> {:error, e, merge(acc, m)}
    end
  end

  defp merge(a, m),
    do: %{ms: a.ms + m.ms, tokens: a.tokens + m.tokens, cost: a.cost + m.cost, rounds: a.rounds + 1}

  def wave(n) do
    IO.puts("\n━━━ WAVE: #{n} concurrent agents ━━━")
    topics = Enum.map(0..(n - 1), fn i -> Enum.at(@topics, rem(i, length(@topics))) end)
    t0 = System.monotonic_time(:millisecond)

    results =
      topics
      |> Enum.map(fn topic -> Task.async(fn -> agent(topic) end) end)
      |> Task.await_many(:infinity)

    wall = System.monotonic_time(:millisecond) - t0
    ok = Enum.filter(results, &match?({:ok, _}, &1))
    bad = Enum.filter(results, &match?({:error, _, _}, &1))

    metas = Enum.map(results, fn
      {:ok, m} -> m
      {:error, _, m} -> m
    end)

    tokens = Enum.sum(Enum.map(metas, & &1.tokens))
    cost = Enum.sum(Enum.map(metas, & &1.cost))
    rounds = Enum.sum(Enum.map(metas, & &1.rounds))
    avg_agent_ms = if metas == [], do: 0, else: round(Enum.sum(Enum.map(metas, & &1.ms)) / length(metas))

    IO.puts("  ok: #{length(ok)}/#{n}   failed: #{length(bad)}")
    IO.puts("  wall: #{Float.round(wall / 1000, 1)}s   avg-agent: #{Float.round(avg_agent_ms / 1000, 1)}s   speedup: #{Float.round(avg_agent_ms * n / max(wall, 1), 1)}x")
    IO.puts("  rounds done: #{rounds}/#{n * 3}   tokens: #{tokens}   cost: $#{Float.round(cost, 4)}")
    if bad != [], do: IO.puts("  errors: #{inspect(Enum.map(bad, fn {:error, e, _} -> e end) |> Enum.frequencies())}")

    %{n: n, ok: length(ok), failed: length(bad), wall_ms: wall, tokens: tokens, cost: cost}
  end

  def run do
    waves =
      System.get_env("WAVES", "4,8,16,32")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    IO.puts("Deep-research stress — search=#{@search_model} synth=#{@synth_model}")
    IO.puts("Ramp: #{inspect(waves)}  (3 LLM rounds/agent; 2 are live web search)")

    summary = Enum.map(waves, &wave/1)

    IO.puts("\n══════════ SUMMARY ══════════")
    IO.puts("agents | ok | fail | wall  | $cost  | $/agent")
    Enum.each(summary, fn s ->
      :io.format("~6w | ~2w | ~4w | ~5.1fs | ~6.4f | ~7.4f~n",
        [s.n, s.ok, s.failed, s.wall_ms / 1000, s.cost, s.cost / max(s.ok, 1)])
    end)
    total = Enum.sum(Enum.map(summary, & &1.cost))
    IO.puts("total spend this run: $#{Float.round(total, 4)}")
  end
end

DeepResearchStress.run()
