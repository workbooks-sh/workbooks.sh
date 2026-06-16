# Pure memory-concurrency: how many concurrent long-horizon agent CONTEXTS fit in RAM?
# No LLM (instant, $0, no rate limits) — isolates the binding constraint (held memory)
# and is the instrument we measure every efficiency optimization against.
#
# Each spawned process builds its OWN realistic agent context (distinct binaries, like
# a real distinct conversation — NOT shared) and holds it alive while we sample peak
# :erlang.memory(:total). Two profiles: a light agent (~30 KB ctx, matches the real
# 27.5 KB we measured) and a heavy one (~200 KB, a long unbounded-context agent).
#
# Run:  mix run bench/agent_memory.exs

mb = fn b -> Float.round(b / 1_048_576, 1) end

# Build a realistic conversation of ~`turns` turns, each ~`chunk` bytes of text
# (assistant message + tool result), like the agent loop accumulates.
build_ctx = fn turns, chunk ->
  base = [
    %{"role" => "system", "content" => :binary.copy("s", 1200)},
    %{"role" => "user", "content" => :binary.copy("u", 400)}
  ]
  turns_msgs =
    Enum.flat_map(1..turns, fn _ ->
      [
        %{"role" => "assistant", "content" => :binary.copy("a", chunk),
          "tool_calls" => [%{"id" => "t", "function" => %{"name" => "vfs_write", "arguments" => "{}"}}]},
        %{"role" => "tool", "content" => :binary.copy("t", chunk)}
      ]
    end)
  base ++ turns_msgs
end

measure = fn n, turns, chunk ->
  :erlang.garbage_collect()
  Process.sleep(50)
  base_mem = :erlang.memory(:total)
  parent = self()

  pids =
    for _ <- 1..n do
      spawn(fn ->
        # build OWN context (distinct binaries — faithful to a real distinct agent)
        ctx = build_ctx.(turns, chunk)
        # mirror the agent's st map + a small working-files map (VFS)
        st = %{messages: ctx, vfs: %{"dossier.md" => :binary.copy("d", chunk * 3)}, step: turns}
        send(parent, :ready)
        receive do :stop -> :ok end
        _ = st
      end)
    end

  Enum.each(1..n, fn _ -> receive do (:ready -> :ok) end end)
  :erlang.garbage_collect()
  Process.sleep(80)
  peak = :erlang.memory(:total)
  net = peak - base_mem
  Enum.each(pids, fn p -> send(p, :stop) end)
  Enum.each(pids, fn p ->
    ref = Process.monitor(p)
    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      2000 -> :ok
    end
  end)
  %{n: n, net: net, per: net / n}
end

IO.puts("\n=== Pure memory-concurrency (no LLM) ===")
IO.puts("BEAM idle: #{mb.(:erlang.memory(:total))} MB\n")

for {label, turns, chunk} <- [{"light agent (~30KB ctx, like real 7-step)", 14, 900}, {"heavy agent (~200KB ctx, long unbounded)", 50, 1800}] do
  IO.puts("#{label}:")
  IO.puts("  #{String.pad_trailing("agents", 9)}#{String.pad_trailing("net MB", 10)}KB/agent")
  per_kb =
    for n <- [200, 1000, 3000] do
      r = measure.(n, turns, chunk)
      IO.puts("  #{String.pad_trailing("#{n}", 9)}#{String.pad_trailing("#{mb.(r.net)}", 10)}#{Float.round(r.per / 1024, 1)}")
      r.per
    end
    |> Enum.max()

  IO.puts("  → ~#{Float.round(per_kb / 1024, 1)} KB/agent (worst). Concurrent contexts a nexus HOLDS:")
  for {rl, ram} <- [{"512 MB", 512}, {"1 GB", 1024}, {"2 GB", 2048}] do
    usable = (ram - 250) * 1_048_576
    IO.puts("     #{String.pad_trailing(rl, 8)} ~#{trunc(usable / per_kb)} agents")
  end
  IO.puts("")
end
