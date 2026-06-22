defmodule Nexus.AgentWorkCliTest do
  @moduledoc """
  wb-c7cp: the agent now has its OWN `work` CLI in-process — the same Nexus.Compile/Nexus.Graph logic the
  runtime + reactor use, run against its /work tree, so it can do compilations + workbook tasks (author →
  `work check` → fix). No wasm, no subprocess, no missing binary; gated on an exec/commands grant.
  """
  use ExUnit.Case, async: false
  alias Nexus.Agent.{Bash, Vfs}

  setup do
    base = Path.join(System.tmp_dir!(), "wb-workcli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, vfs: Vfs.attach(base), dir: base}
  end

  defp put(dir, rel, body), do: File.write!(Path.join(dir, rel), body)

  test "work check reports OK on a clean tree and flags a dangling ref", %{vfs: vfs, dir: dir} do
    put(dir, "a.work", "A unit.\n\nserver :alpha do\n  def hi, do: :ok\nend\n")
    ok = Bash.run(vfs, "work check", %{tools: nil, grant: ["exec"]})
    assert ok =~ "work check: OK"
    assert ok =~ "unit(s)"

    # A backlink to a unit that doesn't exist must be reported as dangling.
    put(dir, "b.work", "See [[nonexistent-thing]] for details.\n")
    bad = Bash.run(vfs, "work check", %{grant: ["exec"]})
    assert bad =~ "problem(s)"
    assert bad =~ "nonexistent-thing"
  end

  test "work structure groups units by kind; work parse lists a file's units", %{vfs: vfs, dir: dir} do
    put(dir, "s.work", "Two units.\n\nserver :svc do\n  def f, do: 1\nend\n\nresource :thing do\n  field :name\nend\n")
    st = Bash.run(vfs, "work structure", %{grant: ["exec"]})
    assert st =~ "server"
    assert st =~ "svc"

    p = Bash.run(vfs, "work parse s.work", %{grant: ["exec"]})
    assert p =~ "svc"
  end

  test "the grant gate: no exec/commands grant → work is refused", %{vfs: vfs, dir: dir} do
    put(dir, "a.work", "A unit.\n\nserver :alpha do\n  def hi, do: :ok\nend\n")
    refused = Bash.run(vfs, "work check", %{tools: nil, grant: ["fs"]})
    assert refused =~ "needs an 'exec' or 'commands' grant"

    # workhorse-style grant (has exec) is allowed.
    allowed = Bash.run(vfs, "work check", %{grant: ["fs", "exec", "browse", "commands"]})
    assert allowed =~ "work check:"
  end

  test "work help always works (even ungranted); unknown verb is reported", %{vfs: vfs} do
    assert Bash.run(vfs, "work help", %{grant: ["fs"]}) =~ "compile + analyze"
    assert Bash.run(vfs, "work bogus", %{grant: ["exec"]}) =~ "unknown verb"
  end
end
