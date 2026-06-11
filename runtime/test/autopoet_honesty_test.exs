defmodule Workbooks.AutopoetHonestyTest do
  use ExUnit.Case, async: false

  # The autopoet honesty gate (wb-wxye): the worker must NOT trust a self-reported
  # DONE — it over-claims (iter-9 returned "DONE … registration blocked by host
  # gap" on a stub toolkit that fails verify). The worker independently runs
  # `wb toolkit verify` on what the run authored; DONE survives only if a fresh
  # toolkit verifies clean. This proves (1) verify discriminates clean vs hollow,
  # and (2) the decision logic downgrades a hollow DONE to OPEN.

  alias Workbooks.Autopoet.Worker

  @root "/tmp/wb-autopoet-honesty-test"

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    on_exit(fn -> File.rm_rf!(@root) end)
    :ok
  end

  # A toolkit is discovered by an org HEADLINE tagged :toolkit: with a
  # :PROPERTIES: drawer (the real format — see toolkits/glyphs/manifest.org), NOT
  # #+TYPE: frontmatter. A knowledge toolkit with no EXEC/caps passes verify once
  # skills/overview.org exists.
  defp manifest(name) do
    """
    #+TITLE: #{name} toolkit
    #+TOOLKIT: #{name}

    * #{name} — honesty-gate fixture                                   :toolkit:
      :PROPERTIES:
      :ID:        #{name}
      :KIND:      knowledge
      :SKILL_DIR: skills/
      :END:

      A minimal knowledge toolkit fixture.
    """
  end

  defp clean_toolkit(name) do
    dir = Path.join(@root, name)
    File.mkdir_p!(Path.join(dir, "skills"))
    File.write!(Path.join(dir, "manifest.org"), manifest(name))
    File.write!(Path.join([dir, "skills", "overview.org"]), "#+TITLE: overview\n\n* overview\n  what this toolkit does.\n")
  end

  defp hollow_toolkit(name) do
    # mirrors the iter-9 rss toolkit: a discoverable :toolkit: headline + a
    # non-overview skill, but NO skills/overview.org → verify must NOT be clean.
    dir = Path.join(@root, name)
    File.mkdir_p!(Path.join(dir, "skills"))
    File.write!(Path.join(dir, "manifest.org"), manifest(name))
    File.write!(Path.join([dir, "skills", "parse.org"]), "#+TITLE: parse\n\n* parse\n  parse a feed.\n")
  end

  # exactly the predicate verify_new/1 uses to decide a toolkit "verified clean"
  defp cleanish?(out), do: not String.contains?(out, "✗") and not String.contains?(out, "no such toolkit")

  test "verify discriminates a clean toolkit from a hollow one" do
    clean_toolkit("good")
    hollow_toolkit("bad")

    good = Workbooks.Toolkits.verify_text("good", @root)
    bad = Workbooks.Toolkits.verify_text("bad", @root)

    assert cleanish?(good), "clean toolkit should verify clean:\n#{good}"
    refute cleanish?(bad), "hollow toolkit must NOT verify clean:\n#{bad}"
  end

  test "drain_one/0 is a no-LLM no-op when inactive or the backlog is empty" do
    # inactive: no def configured
    System.delete_env("WB_AUTOPOET_DEF")
    assert {:inactive, _} = Worker.drain_one()

    # active but empty backlog → :empty (never reaches an LLM call)
    data = "/tmp/wb-drain-empty"
    File.rm_rf!(data)
    File.mkdir_p!(Path.join(data, "autopoet/issues"))
    System.put_env("WB_DATA", data)
    System.put_env("WB_AUTOPOET_DEF", Path.expand("../examples/autopoet/autopoet.org", __DIR__))
    System.put_env("WB_AUTOPOET_WORKDIR", Path.join(data, "ws"))

    assert :empty = Worker.drain_one()
    assert File.dir?(Path.join(data, "ws")), "drain_one should pin/create the workspace"
  after
    System.delete_env("WB_AUTOPOET_DEF")
    System.delete_env("WB_AUTOPOET_WORKDIR")
    System.delete_env("WB_DATA")
  end

  test "decide/2 honors DONE only when verification is clean" do
    assert {:done, note} = Worker.decide("DONE: built x", {:ok, ["x"]})
    assert note =~ "worker-verified: x"

    assert {:open, why} = Worker.decide("DONE: built x", {:fail, "x:\n✗ skills/overview.org present"})
    assert why =~ "verify` FAILED"
    assert why =~ "overview.org"

    assert {:open, why2} = Worker.decide("DONE: edited a skill", :none)
    assert why2 =~ "no verifiable toolkit"
  end
end
