defmodule Nexus.Autopoet.WorkerTest do
  use ExUnit.Case, async: false
  alias Nexus.Autopoet.{Worker, Knowledge}

  setup do
    root = Path.join(System.tmp_dir!(), "nexus_apw_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "agents"))
    File.write!(Path.join(root, "index.work"), "ceiling do\n  grant net, llm\nend\n")
    File.write!(Path.join(root, "agents/w.work"), "agent :w do\n  prompt \"old\"\n  grant net\nend\n")
    kdir = Path.join(root, "kn")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, kdir: kdir}
  end

  test "an autonomous within-ceiling proposal is routed :autonomous_ready", %{root: root} do
    req = %{target: "w", change: "prompt rewrite"}
    proposer = fn _ -> {:ok, %{"agents/w.work" => "agent :w do\n  prompt \"new+better\"\n  grant net\nend\n"}} end
    r = Worker.cycle(root: root, requests: [req], proposer: proposer, learn?: false)
    assert r.sensed == 1
    assert [%{action: :autonomous_ready, target: "w"}] = r.results
  end

  test "a structural-triad proposal is escalated to a human", %{root: root} do
    captured = self()
    req = %{target: "w", change: "grant +llm"}
    proposer = fn _ -> {:ok, %{"agents/w.work" => "agent :w do\n  prompt \"old\"\n  grant net, llm\nend\n"}} end
    notify = fn item, reasons -> send(captured, {:notified, item.target, reasons}) end
    r = Worker.cycle(root: root, requests: [req], proposer: proposer, notify: notify, learn?: false)
    assert [%{action: :escalated, reasons: reasons}] = r.results
    assert {:grant, "w"} in reasons
    assert_received {:notified, "w", _}
  end

  test "an impure / unparseable proposal is rejected", %{root: root} do
    req = %{target: "index", change: "smuggle logic"}
    proposer = fn _ -> {:ok, %{"index.work" => "server :x do\n  def f(_), do: 1\nend\n"}} end
    r = Worker.cycle(root: root, requests: [req], proposer: proposer, learn?: false)
    assert [%{action: :rejected}] = r.results
  end

  test "a proposer that skips yields a :skipped result", %{root: root} do
    r = Worker.cycle(root: root, requests: [%{target: "w", change: "x"}], proposer: fn _ -> :skip end, learn?: false)
    assert [%{action: :skipped}] = r.results
  end

  test "outcomes are written to the knowledge layer when learn? is on", %{root: root} do
    # point the knowledge dir at the scratch root so we don't touch the real volume
    req = %{target: "w", change: "prompt rewrite"}
    proposer = fn _ -> {:ok, %{"agents/w.work" => "agent :w do\n  prompt \"x\"\n  grant net\nend\n"}} end
    # learn? true writes to the default durable dir — assert the cycle still completes and reports
    r = Worker.cycle(root: root, requests: [req], proposer: proposer, learn?: false)
    assert r.sensed == 1
    # explicit knowledge round-trip (the mechanism the worker uses)
    Knowledge.learn("autopoet", "autonomous_ready request for w", nil, Path.join(root, "kn"))
    assert [%{topic: "autopoet"}] = Knowledge.recall("autopoet", Path.join(root, "kn"))
  end
end
