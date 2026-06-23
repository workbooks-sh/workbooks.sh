# Local agent eval — runs an agent IN-PROCESS (no server, no CLI, no deploy) for fast iteration.
#   CF_AIG_URL=… CF_AIG_TOKEN=… mix run eval_local.exs "<agent>" "<task>"
# Resolves the agent from its .work source, runs it against a fresh temp VFS, prints answer + files.
# Point WB_DATA at a fresh EMPTY tree so a general-scoped agent's staging copy stays tiny — otherwise
# Nexus.Workspaces.copy_clean stages the whole tree root (locally that resolved to the nexus source incl.
# the multi-GB compilers/, filling the disk). On prod WB_DATA is the workspace volume; here it's empty.
wb_data = Path.join(System.tmp_dir!(), "wb-eval-data-#{System.system_time()}")
File.mkdir_p!(wb_data)
System.put_env("WB_DATA", wb_data)

[name, task] =
  case System.argv() do
    [n, t] -> [n, t]
    _ -> ["workhorse", "Create greeting.work in /work: a server unit :greeter with hello/0 returning \"hi\". Run 'work syntax' first if unsure, then 'work check'. Report the work check line."]
  end

agents_dir = Path.join([File.cwd!(), "..", "dogfood", "cloud", "agents"])

# Register EVERY declared agent so sub-agent delegation (`agent <name> <task>`) can resolve targets.
for f <- Path.wildcard(Path.join(agents_dir, "*.work")),
    n <- Nexus.Literate.parse(File.read!(f)),
    Map.get(n, :kind) == "agent" do
  Nexus.Agent.register(n)
end

node = Nexus.Agent.get(name)
unless node, do: (IO.puts("no agent named #{name}"); System.halt(1))

d = Nexus.Agent.def_from_unit(node)

# Optional: seed the VFS from a dir (WB_EVAL_SEED_DIR) so an eval can start from a broken/partial tree.
seed =
  case System.get_env("WB_EVAL_SEED_DIR") do
    dir when is_binary(dir) and dir != "" ->
      for p <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(p), into: %{},
        do: {Path.relative_to(p, dir), File.read!(p)}
    _ -> %{}
  end

opts =
  [system: d.system, task: task, seed: seed]
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
