defmodule Nexus.Autopoet.RequestTest do
  use ExUnit.Case, async: true
  alias Nexus.Autopoet.Request

  test "new/1 requires target + change" do
    assert {:error, _} = Request.new(%{change: "grant +net"})
    assert {:error, _} = Request.new(%{target: "self"})
    assert {:ok, r} = Request.new(%{target: "self", change: "grant +net"})
    assert r.target == "self"
    assert r.change == "grant +net"
  end

  test "string and atom keys both accepted; evidence is a list" do
    assert {:ok, r} = Request.new(%{"target" => "scraper", "change" => "tools +xml", "evidence" => "run-123"})
    assert r.target == "scraper"
    assert r.evidence == ["run-123"]
  end

  test "dedup_key ignores why and normalizes the change" do
    {:ok, a} = Request.new(%{target: "self", change: "grant  +NET", why: "because A"})
    {:ok, b} = Request.new(%{target: "self", change: "grant +net", why: "totally different prose"})
    assert Request.dedup_key(a) == Request.dedup_key(b)
  end

  test "different target or change → different key" do
    {:ok, a} = Request.new(%{target: "self", change: "grant +net"})
    {:ok, b} = Request.new(%{target: "other", change: "grant +net"})
    {:ok, c} = Request.new(%{target: "self", change: "grant +llm"})
    assert Request.dedup_key(a) != Request.dedup_key(b)
    assert Request.dedup_key(a) != Request.dedup_key(c)
  end

  test "file/1 emits a typed self_edit.requested event" do
    {:ok, r} = Request.new(%{target: "self", change: "grant +net", why: "untrusted prose"})
    ev = Request.file(r)
    assert ev.kind == "self_edit.requested"
    assert ev.change == "grant +net"
    assert ev.dedup_key == Request.dedup_key(r)
    assert Map.has_key?(ev, :id) and Map.has_key?(ev, :at)
  end

  test "the bash `request` command files fire-and-forget and confirms" do
    out = Nexus.Agent.Bash.run(Nexus.Agent.Vfs.new(), "request self 'grant +net'")
    assert out =~ "filed"
    assert out =~ "no need to wait"
  end
end
