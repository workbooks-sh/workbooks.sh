defmodule Nexus.AutopoiesisE2ETest do
  @moduledoc """
  End-to-end validation of the Autopoiesis v2 loop (wb-a6u3.16) — the whole pipeline wired through the
  REAL modules: ceiling-in-index, effective grant, management, leases, the merge gate, the eval harness,
  the request seam, and the heartbeat worker. Founding case + the adversarial/safety scenarios from the
  design. No mocks of the safety machinery — only the LLM proposer is injected (deterministic).
  """
  use ExUnit.Case, async: false
  alias Nexus.{Agent, Analytics, Telemetry}
  alias Nexus.Autopoet.{Eval, Gate, Lease, Knowledge, Request, Worker}

  setup do
    Lease.clear()
    Analytics.reset()
    Telemetry.reset()

    root = Path.join(System.tmp_dir!(), "nexus_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "agents"))
    File.mkdir_p!(Path.join(root, "public"))
    # root ceiling: net + llm only
    File.write!(Path.join(root, "index.work"), "ceiling do\n  grant net, llm\nend\n")
    # a managed worker agent
    File.write!(Path.join(root, "agents/scraper.work"), "agent :scraper do\n  prompt \"scrape\"\n  grant net\nend\n")
    # a public-facing, FROZEN subtree (injection-exposed)
    File.write!(Path.join(root, "public/index.work"), "management frozen\n")
    File.write!(Path.join(root, "public/lander.work"), "agent :lander do\n  prompt \"public\"\n  grant net\nend\n")

    on_exit(fn -> File.rm_rf(root); Lease.clear(); Analytics.reset(); Telemetry.reset() end)
    {:ok, root: root}
  end

  # ── Founding case: an agent files a typed self-edit request, the autopoet routes it ──
  test "FOUNDING CASE: a within-ceiling improvement is routed autonomous-ready", %{root: root} do
    {:ok, req} = Request.new(%{target: "scraper", change: "prompt: scrape better", why: "stalls on empty pages"})
    item = %{kind: :request, target: req.target, change: req.change}
    proposer = fn _ -> {:ok, %{"agents/scraper.work" => "agent :scraper do\n  prompt \"scrape, retrying empties\"\n  grant net\nend\n"}} end

    %{results: [r]} = Worker.cycle(root: root, requests: [item], proposer: proposer, learn?: false)
    assert r.action == :autonomous_ready
  end

  # ── Safety 1: self-escalation is impossible (ceiling intersection) ──
  test "an agent CANNOT escalate its own grant past the ceiling", %{root: root} do
    # scraper rewrites its own grant to add secrets (outside the [net,llm] ceiling)
    changes = %{"agents/scraper.work" => "agent :scraper do\n  prompt \"scrape\"\n  grant net, secrets\nend\n"}
    v = Eval.validate(root, changes)
    # grant change → human-gated (never autonomous)
    assert v.autonomy == :human_gated
    assert {:grant, "scraper"} in v.reasons
    # and even if it ran, effective grant clamps secrets away
    assert Agent.effective_grant(["net", "secrets"], ["net", "llm"], nil) == ["net"]
  end

  # ── Safety 2: a frozen subtree is untouchable, even for a benign edit (injection defense) ──
  test "the public (frozen) subtree is never autonomously editable", %{root: root} do
    v = Eval.validate(root, %{"public/lander.work" => "agent :lander do\n  prompt \"public reworded\"\n  grant net\nend\n"})
    assert v.autonomy == :human_gated
    assert {:subtree_management, "frozen"} in v.reasons
  end

  # ── Safety 3: a structural-triad change (ceiling) routes to a human ──
  test "widening a ceiling is human-gated", %{root: root} do
    v = Eval.validate(root, %{"index.work" => "ceiling do\n  grant net, llm, secrets\nend\n"})
    assert v.autonomy == :human_gated
    assert :ceiling in v.reasons
  end

  # ── Safety 4: a malformed edit is rejected, never merged ──
  test "an impure index edit fails the verdict", %{root: root} do
    v = Eval.validate(root, %{"index.work" => "server :x do\n  def f(_), do: 1\nend\n"})
    assert v.verdict == :fail
  end

  # ── Leases: a scoped exception lets a principal cross the ceiling, then expires ──
  test "a lease grants a crossing capability, scoped + non-delegable", %{root: _root} do
    Lease.grant("scraper", "secrets", ttl: "5m")
    assert "secrets" in Lease.active("scraper")
    assert Lease.active("other") == []  # non-delegable
    Lease.grant("scraper", "kv", ttl: 0)
    refute "kv" in Lease.active("scraper")  # expired immediately
  end

  # ── Learning: the autopoet records lessons as data ──
  test "outcomes are learnable as durable data", %{root: root} do
    kdir = Path.join(root, "kn")
    Knowledge.learn("autopoet", "scraper improved via prompt retry", "req-1", kdir)
    assert [%{topic: "autopoet"}] = Knowledge.recall("autopoet", kdir)
  end

  # ── Senses: analytics + telemetry feed the heartbeat ──
  test "the autopoet can sense app analytics and agent drift", %{root: _root} do
    Analytics.track("view", "t1"); Analytics.track("view", "t1"); Analytics.track("buy", "t1")
    [v, b] = Analytics.funnel(["view", "buy"], "t1")
    assert v.count == 2 and b.rate == 0.5
    for _ <- 1..4, do: Telemetry.record("doomed", %{at: 0, turns: 1, tokens: %{total: 1}, latency_ms: 1, tools: %{}, status: :error})
    assert Enum.any?(Telemetry.concerns(), fn {k, _s, r} -> k == Nexus.Uid.key("doomed") and :no_success in r end)
  end
end

defmodule Nexus.AutopoiesisBootTest do
  @moduledoc "Local-nexus boot tier of wb-a6u3.16: the running nexus (THIS code) wires the autopoiesis runtime."
  use ExUnit.Case, async: false

  test "the booted nexus has the autopoiesis runtime supervised and alive" do
    # the app is started for the test run (the same supervision tree a local nexus boots)
    assert is_pid(Process.whereis(Nexus.Telemetry))
    assert is_pid(Process.whereis(Nexus.Autopoet.Lease))
    assert is_pid(Process.whereis(Nexus.Analytics))
  end

  test "the autopoet modules are loaded and callable in the booted node" do
    assert function_exported?(Nexus.Autopoet.Worker, :cycle, 1)
    assert function_exported?(Nexus.Autopoet.Gate, :classify, 3)
    assert function_exported?(Nexus.Index, :effective_ceiling, 2)
    # a live call through the supervised tree
    assert Nexus.Analytics.summary("boot-check").total == 0
  end
end
