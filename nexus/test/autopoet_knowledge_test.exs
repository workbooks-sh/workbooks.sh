defmodule Nexus.Autopoet.KnowledgeTest do
  use ExUnit.Case, async: true
  alias Nexus.Autopoet.Knowledge

  setup do
    dir = Path.join(System.tmp_dir!(), "nexus_know_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "learn then recall round-trips a lesson", %{dir: dir} do
    Knowledge.learn("web", "datacenter IPs are blocked by many search providers", "run-2974", dir)
    assert [%{topic: "web", lesson: l, evidence: "run-2974"}] = Knowledge.recall(nil, dir)
    assert l =~ "datacenter IPs"
  end

  test "recall filters by topic", %{dir: dir} do
    Knowledge.learn("web", "lesson A", nil, dir)
    Knowledge.learn("compile", "lesson B", nil, dir)
    assert [%{lesson: "lesson A"}] = Knowledge.recall("web", dir)
    assert Knowledge.count(dir) == 2
  end

  test "an identical lesson is not stored twice (idempotent)", %{dir: dir} do
    Knowledge.learn("x", "same lesson", "ev1", dir)
    Knowledge.learn("x", "same lesson", "ev1", dir)
    assert Knowledge.count(dir) == 1
  end

  test "lessons persist across reads (durable file)", %{dir: dir} do
    Knowledge.learn("a", "first", nil, dir)
    Knowledge.learn("b", "second", nil, dir)
    # fresh read sees both
    assert length(Knowledge.recall(nil, dir)) == 2
    assert File.exists?(Knowledge.path(dir))
  end

  test "the store is a .work file with no JSON", %{dir: dir} do
    Knowledge.learn("a", "no braces here", nil, dir)
    body = File.read!(Knowledge.path(dir))
    assert String.ends_with?(Knowledge.path(dir), ".work")
    refute body =~ "{"
  end
end
