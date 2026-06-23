defmodule Nexus.HashNote.SweepTest do
  use ExUnit.Case, async: false

  alias Nexus.HashNote
  alias Nexus.HashNote.Sweep

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  @ctx %{sweep_sha: "abc1234def", author: "waldo <waldo>"}

  test "drawered -# collapses to a ≡handle; +# stays on the desk" do
    src = """
    # Toolkit

    +# pinned: guest shim is next
    -# dropped krunvm here, libkrun deadlocked the BEAM
    server :api do
      :ok
    end
    """

    {new_src, records} = Sweep.sweep_source(src, "toolkit.work", @ctx)

    # the pin is untouched
    assert new_src =~ "+# pinned: guest shim is next"
    # the drawered note became a handle (sweep-sha prefix), text gone from source
    refute new_src =~ "-# dropped krunvm"
    assert new_src =~ "≡abc1234 dropped krunvm here"
    # exactly one drawer row, carrying the full text
    assert [rec] = records
    assert rec.hash == "abc1234"
    assert rec.polarity == :drawer and rec.state == :collapsed
    assert rec.text =~ "libkrun deadlocked"
    assert rec.swept_at == "abc1234def"
    # the code block survived intact
    assert new_src =~ "server :api do"
  end

  test "multiple drawered notes get suffixed handles; nesting sets parent" do
    src = """
    -# parent caution
      -# child caution
    """

    {new_src, records} = Sweep.sweep_source(src, "f.work", @ctx)

    assert [parent, child] = records
    assert parent.hash == "abc1234"
    assert child.hash == "abc1234.1"
    assert child.parent == "abc1234"
    assert new_src =~ "≡abc1234 parent caution"
    assert new_src =~ "  ≡abc1234.1 child caution"
  end

  test "sweep_dir rewrites files on disk and persists rows; re-sweep is a no-op" do
    dir = Path.join(System.tmp_dir!(), "sweep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "notes.work")
    File.write!(path, "intro\n-# collapse me please\n")

    n = Sweep.sweep_dir(dir, @ctx)
    assert n == 1
    assert File.read!(path) =~ "≡abc1234 collapse me please"
    assert HashNote.fetch("abc1234").text == "collapse me please"

    # nothing live left → a second sweep collapses nothing
    assert Sweep.sweep_dir(dir, %{sweep_sha: "zzz9999"}) == 0

    File.rm_rf!(dir)
  end

  test "long note text is truncated in the handle summary but full in the drawer" do
    long = String.duplicate("x", 120)
    {new_src, [rec]} = Sweep.sweep_source("-# #{long}\n", "f.work", @ctx)
    assert String.length(rec.text) == 120
    assert new_src =~ "…"
    refute new_src =~ long
  end
end
