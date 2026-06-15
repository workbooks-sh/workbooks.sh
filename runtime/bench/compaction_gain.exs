# Deterministic compaction gain: force a long-horizon (30-turn) agent session via a mock
# LLM (no network, no cost) and measure the context bytes SENT to the model each turn —
# a direct token proxy — with compaction OFF vs ON. Without compaction context grows
# O(N^2) over a session (every turn resends the whole growing transcript); with it the
# context is capped, so cumulative tokens collapse on long runs.
#
# Run:  mix run bench/compaction_gain.exs

alias Workbooks.Agent

chunk = 1500
max = 30

run = fn compact ->
  parent = self()

  mock = fn messages, _opts ->
    # record the size of the context handed to the "model" this turn (token proxy)
    send(parent, {:ctx, byte_size(:erlang.term_to_binary(messages))})
    assistant_turns = Enum.count(messages, fn m -> (m["role"] || m[:role]) == "assistant" end)

    if assistant_turns >= max - 1 do
      {:ok, %{tool_calls: [], content: "done after #{assistant_turns} turns"}}
    else
      args = %{"path" => "notes.md", "content" => :binary.copy("c", chunk)}
      {:ok,
       %{
         content: nil,
         raw_message: %{
           "role" => "assistant",
           "content" => :binary.copy("a", chunk),
           "tool_calls" => [%{"id" => "t", "function" => %{"name" => "vfs_write", "arguments" => Jason.encode!(args)}}]
         },
         tool_calls: [%{id: "t", name: "vfs_write", args: args}]
       }}
    end
  end

  Agent.run("You are a long-horizon agent.", "Work the task across many steps.",
    complete_fn: mock, max_steps: max, compact: compact, truncate_tools: compact)

  collect = fn collect, acc ->
    receive do
      {:ctx, n} -> collect.(collect, [n | acc])
    after
      150 -> Enum.reverse(acc)
    end
  end

  collect.(collect, [])
end

tok = fn bytes -> div(bytes, 4) end # ~4 bytes/token rough proxy

off = run.(false)
on = run.(true)

off_tot = Enum.sum(off)
on_tot = Enum.sum(on)
cut = Float.round((off_tot - on_tot) * 100 / off_tot, 1)

IO.puts("\n=== Compaction gain (deterministic, #{max}-turn session, no LLM) ===")
IO.puts("turns measured: off=#{length(off)} on=#{length(on)}")
IO.puts("peak context/turn:  off=#{tok.(Enum.max(off))} tok   on=#{tok.(Enum.max(on))} tok")
IO.puts("CUMULATIVE tokens sent over the session:")
IO.puts("  OFF (unbounded): #{tok.(off_tot)} tok")
IO.puts("  ON  (compacted): #{tok.(on_tot)} tok")
IO.puts("  → #{cut}% fewer tokens over a #{max}-turn session")
IO.puts("\n(the gap widens with session length: OFF is O(N^2), ON is ~O(N))")
