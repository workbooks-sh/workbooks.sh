# Evaluate the LIVE channel across DIFFERENT KINDS of runs. Each run collects its full event stream; we
# report what events each kind produced (tokens, tool calls, nesting depth, flow steps, timing) so we can
# see the channel behaves correctly per kind.  CF_AIG_URL=… CF_AIG_TOKEN=… mix run eval_live.exs
Nexus.Config.put(:jj_substrate, true)
for f <- Path.wildcard(Path.join([File.cwd!(),"..","dogfood","cloud","agents","*.work"])),
    node <- Nexus.Literate.parse(File.read!(f)), Map.get(node,:kind)=="agent", do: Nexus.Agent.register(node)
wh = Nexus.Agent.def_from_unit(Nexus.Agent.get("workhorse"))

defmodule Collector do
  def start, do: Agent.start_link(fn -> [] end)
  def emit(a), do: fn ev -> Agent.update(a, &[ev | &1]) end
  def events(a), do: Agent.get(a, & &1) |> Enum.reverse()
end

# Summarize a collected event stream into comparable stats.
summary = fn events ->
  by_type = Enum.frequencies_by(events, & &1[:type])
  tokens = Enum.filter(events, &(&1[:type] == "token"))
  token_chars = tokens |> Enum.map(&String.length(&1[:content] || "")) |> Enum.sum()
  max_depth = events |> Enum.map(&(&1[:depth] || 0)) |> Enum.max(fn -> 0 end)
  agents = events |> Enum.map(& &1[:agent]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  %{
    total: length(events),
    tokens: map_size(Map.take(by_type, ["token"])) > 0 && length(tokens) || 0,
    token_chars: token_chars,
    tool_turns: Map.get(by_type, "tools", 0),
    agent_starts: Map.get(by_type, "agent_start", 0),
    step_events: Map.get(by_type, "step_start", 0),
    max_depth: max_depth,
    finals: Map.get(by_type, "final", 0),
    distinct_agents: length(agents),
    types: by_type
  }
end

run_agent = fn opts ->
  {:ok, c} = Collector.start()
  t0 = System.monotonic_time(:millisecond)
  res = Nexus.Agent.run(Keyword.put(opts, :emit, Collector.emit(c)))
  {match?({:ok,_}, res), System.monotonic_time(:millisecond) - t0, Collector.events(c)}
end

base = [kits: wh[:tools], grant: wh[:grant], model: wh[:model], system: wh.system]

IO.puts("\n================ LIVE-CHANNEL EVAL: multiple run kinds ================\n")
results = []

# KIND 1 — pure text (token stream, no tools)
{ok1, ms1, ev1} = run_agent.(base ++ [task: "Count from 1 to 6, one per line, then say done.", limit: [turns: 2, timeout: 60_000]])
results = results ++ [{"1·text-stream", ok1, ms1, summary.(ev1)}]

# KIND 2 — authoring (tokens + tools)
{ok2, ms2, ev2} = run_agent.(base ++ [task: "Create /work/hi.work with server :hi (ping/0 -> :ok). Run 'work check'.", limit: [turns: 8, timeout: 90_000]])
results = results ++ [{"2·authoring", ok2, ms2, summary.(ev2)}]

# KIND 3 — self-correction (fix a seeded broken file)
{ok3, ms3, ev3} = run_agent.(base ++ [seed: %{"bad.work" => "server :bad do\n  def f, do: :ok\n"}, task: "Run 'work check', fix every problem in /work, re-run until OK.", limit: [turns: 10, timeout: 120_000]])
results = results ++ [{"3·self-correct", ok3, ms3, summary.(ev3)}]

# KIND 4 — orchestration (parallel sub-agents on a shared workspace; nested progress)
root = Path.join(System.tmp_dir!(), "wb-live-#{System.system_time()}")
bare = Nexus.Git.bare_path(Path.join(root,"repos"),"site"); work_dir = Path.join(Path.join(root,"work"),"site")
{:ok,_} = Nexus.Git.provision_remote(bare, work_dir)
File.write!(Path.join(work_dir,"index.work"),"Site.\n\nserver :site do\n  def n, do: :ok\nend\n")
{:ok,_} = Nexus.JJ.commit_change(bare, work_dir, "seed", author: "seed <seed>")
ws = %{bare: bare, work_dir: work_dir, name: "site", branch: "agent/orch", mode: "fifo"}
otask = "In ONE turn issue both:\n  agent workhorse \"create /work/x.work with server :xx (ping/0 -> :ok), then work check\"\n  agent workhorse \"create /work/y.work with server :yy (ping/0 -> :ok), then work check\""
{ok4, ms4, ev4} = run_agent.(base ++ [task: otask, workspace: ws, limit: [turns: 12, timeout: 200_000]])
results = results ++ [{"4·orchestration", ok4, ms4, summary.(ev4)}]
File.rm_rf(root)

# KIND 5 — flow (step progress, no LLM)
Nexus.Flow.register(%{name: "demo", steps: [%{name: :scope, effect: %{name: "notify", args: %{}}}, %{name: :build, effect: %{name: "notify", args: %{}}}, %{name: :ship, effect: %{name: "notify", args: %{}}}]})
{:ok, c5} = Collector.start()
t5 = System.monotonic_time(:millisecond)
{:ok, _} = Nexus.Flow.run("demo", "in", %{emit: Collector.emit(c5)})
ev5 = Collector.events(c5)
results = results ++ [{"5·flow", true, System.monotonic_time(:millisecond) - t5, summary.(ev5)}]

# ── report ──
IO.puts(String.pad_trailing("KIND", 18) <> "ok   ms     events tokens(chars)  toolTurns  subAgents  maxDepth  steps  finals")
for {name, ok, ms, s} <- results do
  IO.puts(
    String.pad_trailing(name, 18) <>
    String.pad_trailing(to_string(ok), 5) <>
    String.pad_trailing(to_string(ms), 7) <>
    String.pad_trailing("#{s.total}", 7) <>
    String.pad_trailing("#{s.tokens}(#{s.token_chars})", 14) <>
    String.pad_trailing("#{s.tool_turns}", 11) <>
    String.pad_trailing("#{s.agent_starts}", 11) <>
    String.pad_trailing("#{s.max_depth}", 10) <>
    String.pad_trailing("#{s.step_events}", 7) <>
    "#{s.finals}"
  )
end
IO.puts("\nper-kind event types:")
for {name, _ok, _ms, s} <- results, do: IO.puts("  #{name}: #{inspect(s.types)}")
