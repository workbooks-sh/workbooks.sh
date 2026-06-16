# Nexus capacity benchmark — how many concurrent long-horizon agents can ONE engine
# hold, and what's the memory footprint per agent? Drives the pricing calculator's
# "always-on apps/agents" numbers.
#
# Runs the REAL agent loop (real context growth + real in-memory VFS tool exec) with
# REAL but FREE OpenRouter models, rotated + failover-on-429 so we pay nothing and
# don't abuse any single free model. The LLM is external (its latency/429s are NOT a
# nexus property) — what we measure here is the ENGINE's memory/process load per
# concurrent agent session, which is what a nexus's RAM actually caps.
#
# Run:  set -a; . ~/.workbooks/*.env; set +a
#       mix run bench/agent_capacity.exs

free = [
  "openai/gpt-oss-120b:free",
  "openai/gpt-oss-20b:free",
  "nvidia/nemotron-3-nano-30b-a3b:free",
  "nvidia/nemotron-nano-9b-v2:free"
]

# round-robin index shared across all agent processes
ctr = :atomics.new(1, signed: false)
pick = fn -> Enum.at(free, rem(:atomics.add_get(ctr, 1, 1), length(free))) end

# complete_fn: try each free model once per turn, rotating, until one answers.
# (retries: 0 so we fail FAST to the next model instead of sleeping on a 429.)
complete_fn = fn messages, opts ->
  Enum.reduce_while(1..length(free), {:error, :all_busy}, fn _, _ ->
    case Workbooks.Llm.complete(messages, opts |> Keyword.put(:model, pick.()) |> Keyword.put(:retries, 0)) do
      {:ok, r} -> {:halt, {:ok, r}}
      {:error, _} -> {:cont, {:error, :busy}}
    end
  end)
end

system = """
You are a research agent building a dossier file. Each turn, call vfs_write to APPEND
one more detailed section (~1500 characters, 3-4 paragraphs) to dossier.md — keep the
prior content and add to it so the file grows. Work section by section. After you've
written several sections, call done with a one-line summary.
"""

task = "Build a thorough dossier on: failure modes of large distributed systems. Write at least 6 sections."

mb = fn bytes -> Float.round(bytes / 1_048_576, 1) end

# sample :erlang.memory(:total) + process_count every 120ms; return {peak_mem, peak_procs}
sample = fn run_fn ->
  parent = self()
  sampler = spawn(fn ->
    loop = fn loop, peak_m, peak_p ->
      receive do
        :stop -> send(parent, {:peak, peak_m, peak_p})
      after
        120 ->
          loop.(loop, max(peak_m, :erlang.memory(:total)), max(peak_p, :erlang.system_info(:process_count)))
      end
    end
    loop.(loop, :erlang.memory(:total), :erlang.system_info(:process_count))
  end)

  result = run_fn.()
  send(sampler, :stop)
  receive do {:peak, m, p} -> {result, m, p} end
end

:erlang.garbage_collect()
baseline = :erlang.memory(:total)
IO.puts("\n=== Nexus agent-capacity benchmark ===")
IO.puts("baseline (idle engine): #{mb.(baseline)} MB · #{:erlang.system_info(:process_count)} procs")
IO.puts("models (rotated): #{Enum.join(free, ", ")}\n")
IO.puts(String.pad_trailing("agents", 8) <> String.pad_trailing("ok", 5) <> String.pad_trailing("peak MB", 10) <> String.pad_trailing("net MB", 9) <> String.pad_trailing("MB/agent", 10) <> String.pad_trailing("avg ctx KB", 12) <> String.pad_trailing("avg steps", 10) <> "wall s")

results =
  for m <- [1, 4, 8, 16] do
    {agent_results, peak_mem, peak_procs} =
      sample.(fn ->
        t0 = System.monotonic_time(:millisecond)
        rs =
          1..m
          |> Task.async_stream(
            fn i ->
              r = Workbooks.Agent.run(system, task, complete_fn: complete_fn, max_steps: 7, tenant: "bench-#{i}")
              # final context size = bytes of the conversation this agent held
              ctx = byte_size(:erlang.term_to_binary(r[:events] || []))
              %{ok: match?(%{result: _}, r) or is_map(r), steps: length(r[:events] || []), ctx: ctx}
            end,
            max_concurrency: m,
            timeout: 240_000
          )
          |> Enum.map(fn {:ok, v} -> v end)
        {rs, System.monotonic_time(:millisecond) - t0}
      end)

    {rs, wall} = agent_results
    ok = Enum.count(rs, & &1.ok)
    net = peak_mem - baseline
    avg_ctx = if rs == [], do: 0, else: Enum.sum(Enum.map(rs, & &1.ctx)) / length(rs) / 1024
    avg_steps = if rs == [], do: 0, else: Enum.sum(Enum.map(rs, & &1.steps)) / length(rs)

    IO.puts(
      String.pad_trailing("#{m}", 8) <>
      String.pad_trailing("#{ok}", 5) <>
      String.pad_trailing("#{mb.(peak_mem)}", 10) <>
      String.pad_trailing("#{mb.(net)}", 9) <>
      String.pad_trailing("#{Float.round(net / 1_048_576 / m, 2)}", 10) <>
      String.pad_trailing("#{Float.round(avg_ctx, 1)}", 12) <>
      String.pad_trailing("#{Float.round(avg_steps, 1)}", 10) <>
      "#{Float.round(wall / 1000, 1)}"
    )

    :erlang.garbage_collect()
    %{m: m, net: net, per_agent: net / m, procs: peak_procs}
  end

# Extrapolate: a nexus at RAM R. Assume ~150 MB engine baseline + 100 MB OS/headroom.
per_agent_bytes = results |> Enum.map(& &1.per_agent) |> Enum.max()
IO.puts("\nper-agent footprint (worst observed): #{mb.(round(per_agent_bytes))} MB")
IO.puts("\nestimated concurrent long-horizon agents a nexus can HOLD (memory-bound):")
for {label, ram_mb} <- [{"512 MB", 512}, {"1 GB", 1024}, {"2 GB", 2048}, {"4 GB", 4096}] do
  usable = (ram_mb - 250) * 1_048_576
  n = max(0, trunc(usable / per_agent_bytes))
  IO.puts("  #{String.pad_trailing(label, 8)} ~#{n} agents")
end
IO.puts("\n(LLM latency/429s are EXTERNAL — they cap how fast agents progress, not how")
IO.puts(" many a nexus holds. Idle agents waiting on the model cost ~only their context.)")
