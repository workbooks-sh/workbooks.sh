defmodule Nexus.Autopoet.EvalTest do
  use ExUnit.Case, async: true
  alias Nexus.Autopoet.Eval

  setup do
    root = Path.join(System.tmp_dir!(), "nexus_eval_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "agents"))
    File.write!(Path.join(root, "index.work"), "ceiling do\n  grant net, llm\nend\n")
    File.write!(Path.join(root, "agents/w.work"), "agent :w do\n  prompt \"old\"\n  grant net\nend\n")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "a managed prompt tweak passes and is autonomous", %{root: root} do
    r = Eval.validate(root, %{"agents/w.work" => "agent :w do\n  prompt \"new+better\"\n  grant net\nend\n"})
    assert r.verdict == :pass
    assert r.autonomy == :autonomous
  end

  test "a grant change is valid (:pass) but routes to a human", %{root: root} do
    r = Eval.validate(root, %{"agents/w.work" => "agent :w do\n  prompt \"old\"\n  grant net, llm\nend\n"})
    assert r.verdict == :pass
    assert r.autonomy == :human_gated
    assert {:grant, "w"} in r.reasons
  end

  test "an impure index (smuggled logic) fails the verdict", %{root: root} do
    r = Eval.validate(root, %{"index.work" => "server :x do\n  def f(_), do: 1\nend\n"})
    assert r.verdict == :fail
    assert Map.has_key?(r.impure_indexes, "index.work")
  end

  test "scratch is cleaned up after validation", %{root: root} do
    r = Eval.validate(root, %{"agents/w.work" => "agent :w do\n  prompt \"x\"\n  grant net\nend\n"})
    refute File.exists?(r.scratch)
  end

  test "the live tree is never mutated by validation", %{root: root} do
    before = File.read!(Path.join(root, "agents/w.work"))
    Eval.validate(root, %{"agents/w.work" => "agent :w do\n  prompt \"DIFFERENT\"\n  grant net\nend\n"})
    assert File.read!(Path.join(root, "agents/w.work")) == before
  end
end
