# Local agent eval — runs an agent IN-PROCESS (no server, no CLI, no deploy) for fast iteration.
#   CF_AIG_URL=… CF_AIG_TOKEN=… mix run eval_local.exs "<agent>" "<task>"
# Resolves the agent from its .work source, runs it against a fresh temp VFS, prints answer + files.
[name, task] =
  case System.argv() do
    [n, t] -> [n, t]
    _ -> ["workhorse", "Create greeting.work in /work: a server unit :greeter with hello/0 returning \"hi\". Run 'work syntax' first if unsure, then 'work check'. Report the work check line."]
  end

src = File.read!(Path.join([File.cwd!(), "..", "dogfood", "cloud", "agents", "#{name}.work"]))
node = src |> Nexus.Literate.parse() |> Enum.find(&(Map.get(&1, :kind) == "agent"))
unless node, do: (IO.puts("no agent in #{name}.work"); System.halt(1))

d = Nexus.Agent.def_from_unit(node)

opts =
  [system: d.system, task: task]
  |> then(&(if d[:tools], do: Keyword.put(&1, :kits, d[:tools]), else: &1))
  |> then(&(if d[:grant], do: Keyword.put(&1, :grant, d[:grant]), else: &1))
  |> then(&(if d[:model], do: Keyword.put(&1, :model, d[:model]), else: &1))
  |> Keyword.put(:limit, d[:limit] || [turns: 60, timeout: 300_000])

IO.puts("== local eval: #{name} (model=#{d[:model]}) ==")
t0 = System.monotonic_time(:millisecond)

case Nexus.Agent.run(opts) do
  {:ok, res} ->
    dt = System.monotonic_time(:millisecond) - t0
    IO.puts("\n--- ANSWER (#{res.turns} turns, #{dt}ms) ---\n#{res.answer}")
    IO.puts("\n--- VFS FILES ---\n#{inspect(res.vfs_files)}")

  {:error, e} ->
    IO.puts("ERROR: #{inspect(e)}")
    System.halt(1)
end
