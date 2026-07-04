defmodule Nexus.Autopoet.GateTest do
  use ExUnit.Case, async: true
  alias Nexus.Autopoet.Gate

  defp agent(name, body), do: "agent :#{name} do\n#{body}\nend\n"

  test "editing a managed agent's prompt is autonomous" do
    old = agent("w", "  prompt \"old\"\n  grant net")
    new = agent("w", "  prompt \"new and improved\"\n  grant net")
    assert Gate.classify("agents/w.work", old, new) == {:autonomous, []}
  end

  test "changing an agent's grant is human-gated" do
    old = agent("w", "  prompt \"hi\"\n  grant net")
    new = agent("w", "  prompt \"hi\"\n  grant net, secrets")
    assert {:human_gated, reasons} = Gate.classify("agents/w.work", old, new)
    assert {:grant, "w"} in reasons
  end

  test "changing an agent's management posture is human-gated (no self-promotion)" do
    old = agent("w", "  prompt \"hi\"\n  management frozen")
    new = agent("w", "  prompt \"hi\"\n  management managed")
    assert {:human_gated, reasons} = Gate.classify("agents/w.work", old, new)
    # frozen target → frozen reason fires first, the key point: NOT autonomous
    assert {:frozen, "w"} in reasons
  end

  test "any edit to a frozen agent is human-gated, even a benign prompt tweak" do
    old = agent("tw", "  prompt \"old\"\n  management frozen")
    new = agent("tw", "  prompt \"new\"\n  management frozen")
    assert {:human_gated, [{:frozen, "tw"}]} = Gate.classify("agents/tw.work", old, new)
  end

  test "a proposed agent always routes to a human" do
    old = agent("p", "  prompt \"old\"\n  management proposed")
    new = agent("p", "  prompt \"new\"\n  management proposed")
    assert {:human_gated, [{:proposed, "p"}]} = Gate.classify("agents/p.work", old, new)
  end

  test "changing an index ceiling is human-gated" do
    old = "ceiling do\n  grant net\nend\n"
    new = "ceiling do\n  grant net, llm\nend\n"
    assert {:human_gated, reasons} = Gate.classify("index.work", old, new)
    assert :ceiling in reasons
  end

  test "an index edit that leaves the ceiling untouched is autonomous" do
    old = "# docs\nceiling do\n  grant net\nend\n"
    new = "# docs (reworded)\nceiling do\n  grant net\nend\n"
    assert Gate.classify("index.work", old, new) == {:autonomous, []}
  end

  # birthing armed workers IS a grant change (nothing -> caps) — found by the
  # persona task-suite eval: a brain could previously self-hire an agent WITH
  # grant net autonomously, because only grant EDITS on existing agents were checked
  test "a brand-new agent born WITH a grant is human-gated" do
    old = "# crew\n"
    new = "# crew\n\nagent :clerk do\n  prompt \"file things\"\n  grant net\nend\n"
    assert {:human_gated, reasons} = Gate.classify("crew.work", old, new)
    assert {:grant, "clerk"} in reasons
  end

  test "a brand-new agent with NO grants stays autonomous (a harmless organ)" do
    old = "# crew\n"
    new = "# crew\n\nagent :scribe do\n  prompt \"summarize things\"\nend\n"
    assert Gate.classify("crew.work", old, new) == {:autonomous, []}
  end
end
