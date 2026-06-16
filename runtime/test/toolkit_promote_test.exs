defmodule Workbooks.ToolkitPromoteTest do
  @moduledoc """
  wb-rhs.6 — the lifecycle ladder. promote/4 turns an ephemeral session command
  (inline source, built into :persistent_term) into a durable, source-owned
  workspace toolkit that is discoverable, buildable, and packable — the rung
  between self-authoring (wb-rhs.4) and distribution (wb-rhs.7).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Toolkits, CommandRegistry}

  defp uniq(p), do: "#{p}_#{System.unique_integer([:positive])}"

  defp tmp_root do
    d = Path.join(System.tmp_dir!(), "wb-promote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    d
  end

  @rev_src ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|

  test "promote scaffolds a discoverable, buildable workspace toolkit" do
    root = tmp_root()
    name = uniq("rev")
    src = Path.join(System.tmp_dir!(), "#{name}.js")
    File.write!(src, @rev_src)

    out = Toolkits.promote_text(name, "js", src, root: root)
    assert out =~ "promoted session command"

    dir = Path.join(root, name)
    # The durable, source-owned scaffold.
    assert File.regular?(Path.join(dir, "manifest.html"))
    assert File.regular?(Path.join(dir, "src/index.js"))
    assert File.regular?(Path.join(dir, "skills/overview.md"))

    manifest = File.read!(Path.join(dir, "manifest.html"))
    assert manifest =~ ~s(exec="command")
    assert manifest =~ ~s(trust="first-party")
    assert manifest =~ ~s(build-lang="js")
    assert manifest =~ ~s(build-src="path:src")

    # Discoverable as a toolkit by the same query agents use.
    discovered = Toolkits.discover(manifest)
    assert Enum.any?(discovered, &(&1[:id] == name or &1["id"] == name))
  end

  test "promote refuses reserved names and bad input without writing anything" do
    root = tmp_root()
    src = Path.join(System.tmp_dir!(), "x.js")
    File.write!(src, "x")

    assert Toolkits.promote_text("jq", "js", src, root: root) =~ "reserved"
    assert Toolkits.promote_text("bad name", "js", src, root: root) =~ "invalid"
    assert Toolkits.promote_text(uniq("t"), "brainfuck", src, root: root) =~ "unsupported"
    assert Toolkits.promote_text(uniq("t"), "js", "/no/such/file.js", root: root) =~ "no such source"
    # Nothing was created for the bad cases.
    assert File.ls!(root) == []
  end

  @tag :build
  test "FULL ladder: promote → wb toolkit build → registered → run" do
    root = tmp_root()
    name = uniq("rev")
    src = Path.join(System.tmp_dir!(), "#{name}.js")
    File.write!(src, @rev_src)

    # do_build_clause resolves the build dir via default_root(); point it at our
    # temp workspace so the promoted toolkit builds in isolation.
    prev = System.get_env("WB_TOOLKITS_ROOT")
    System.put_env("WB_TOOLKITS_ROOT", root)

    try do
      assert Toolkits.promote_text(name, "js", src, root: root) =~ "promoted"
      # The promoted toolkit builds + registers its command via the normal path.
      assert Toolkits.build_text(name) =~ "registered command"
      assert name in CommandRegistry.list()
      assert {:ok, "cba"} = CommandRegistry.run(name, "abc")
    after
      if prev, do: System.put_env("WB_TOOLKITS_ROOT", prev), else: System.delete_env("WB_TOOLKITS_ROOT")
    end
  end
end
