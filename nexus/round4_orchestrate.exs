# Round 4 (orchestration): WORKHORSE drives multiple sub-agents to build ONE shared workspace.
# The orchestrator runs workspace-scoped; each delegated sub-agent inherits the workspace on its OWN
# branch/worktree and FIFO-integrates into main (lock-serialized). All-delegation turns run in parallel.
#   CF_AIG_URL=… CF_AIG_TOKEN=… mix run round4_orchestrate.exs [N]
Nexus.Config.put(:jj_substrate, true)
unless Nexus.JJ.substrate?(), do: (IO.puts("jj substrate unavailable"); System.halt(1))
n = case System.argv() do [a | _] -> String.to_integer(a); _ -> 3 end

agents_dir = Path.join([File.cwd!(), "..", "dogfood", "cloud", "agents"])
for f <- Path.wildcard(Path.join(agents_dir, "*.work")),
    node <- Nexus.Literate.parse(File.read!(f)),
    Map.get(node, :kind) == "agent",
    do: Nexus.Agent.register(node)

d = Nexus.Agent.def_from_unit(Nexus.Agent.get("workhorse"))

# Shared workspace, seeded main.
root = Path.join(System.tmp_dir!(), "wb-orch-#{System.system_time()}")
bare = Nexus.Git.bare_path(Path.join(root, "repos"), "site")
work_dir = Path.join(Path.join(root, "work"), "site")
{:ok, _} = Nexus.Git.provision_remote(bare, work_dir)
File.write!(Path.join(work_dir, "index.work"), "Shared site.\n\nserver :site do\n  def name, do: \"site\"\nend\n")
{:ok, _} = Nexus.JJ.commit_change(bare, work_dir, "seed", author: "seed <seed>")

parts = for i <- 1..n, do: "part-#{i}"
delegations = parts |> Enum.map_join("\n", fn p -> "  agent workhorse \"Create /work/#{p}.work containing a short prose line and a server unit named :#{String.replace(p, "-", "")} with a function ping/0 returning :ok. Then run 'work check'. Keep it minimal.\"" end)

task = """
You are ORCHESTRATING the build of a shared workspace. Delegate each part to a sub-agent. In a SINGLE turn,
issue all of these delegation commands (they will run in parallel), then report which parts you delegated:
#{delegations}
"""

ws = %{bare: bare, work_dir: work_dir, name: "site", branch: "agent/orchestrator", author: "workhorse <workhorse>", message: "orchestrate", mode: "fifo"}
opts =
  [system: d.system, task: task, workspace: ws]
  |> then(&(if d[:tools], do: Keyword.put(&1, :kits, d[:tools]), else: &1))
  |> then(&(if d[:grant], do: Keyword.put(&1, :grant, d[:grant]), else: &1))
  |> then(&(if d[:model], do: Keyword.put(&1, :model, d[:model]), else: &1))
  |> Keyword.put(:limit, [turns: 30, timeout: 280_000])

IO.puts("== workhorse orchestrating #{n} sub-agents on a shared workspace ==")
t0 = System.monotonic_time(:millisecond)
res = Nexus.Agent.run(opts)
dt = System.monotonic_time(:millisecond) - t0
IO.puts("== orchestrator done in #{dt}ms: #{inspect(match?({:ok,_}, res))} ==")
case res do {:ok, %{answer: a}} -> IO.puts("\n--- orchestrator answer ---\n#{a}"); _ -> :ok end

{tree, _} = System.cmd("jj", ["--repository", work_dir, "file", "list", "-r", "main"], stderr_to_stdout: true)
files = tree |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".work")) |> Enum.map(&Path.basename/1) |> Enum.sort()
IO.puts("\n--- main's tree (the shared workspace) ---\n#{inspect(files)}")
landed = Enum.count(parts, &("#{&1}.work" in files))
IO.puts("== RESULT: #{landed}/#{n} parts built into the shared workspace by delegated sub-agents ==")
File.rm_rf(root)
