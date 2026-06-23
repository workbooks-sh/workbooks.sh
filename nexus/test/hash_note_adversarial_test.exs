defmodule Nexus.HashNoteAdversarialTest do
  use ExUnit.Case, async: false

  alias Nexus.{Literate, HashNote}
  alias Nexus.HashNote.{Sweep, Guard}

  defp notes(src), do: src |> Literate.parse() |> Enum.filter(&(&1.type == :note))

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  # ── parser: malformed / boundary markers ────────────────────────────────────

  test "empty and no-space notes parse with the right text" do
    assert [%{text: ""}] = notes("+#")
    assert [%{text: "x"}] = notes("+#x")
    assert [%{text: "y"}] = notes("-#  y")
  end

  test "a bare ≡ with no hash is prose, not a handle" do
    assert notes("≡") == []
    assert notes("≡ ") == []
    assert [%{type: :prose}] = Literate.parse("≡")
  end

  test "'+ #' (space between) and headings are NOT notes" do
    assert notes("+ # not a note") == []
    assert notes("# Heading") == []
    assert notes("- bullet item") == []
  end

  test "notes inside a fenced code block are protected (not parsed as notes)" do
    src = "intro\n\n```\n+# this is an example, not a real note\n-# nor this\n```\n\nout\n"
    assert notes(src) == []
  end

  test "notes inside a do…end unit body are part of the body, not notes" do
    src = "server :x do\n  +# inside body\n  :ok\nend\n"
    assert notes(src) == []
    assert [%{type: :code, kind: "server"}] = Literate.parse(src) |> Enum.filter(&(&1.type == :code))
  end

  test "a note as the very last line with no trailing newline still parses" do
    assert [%{polarity: :drawer, text: "eof note"}] = notes("prose\n-# eof note")
  end

  test "unicode in note text survives" do
    assert [%{text: "caution ⚠️ déjà vu 日本語"}] = notes("+# caution ⚠️ déjà vu 日本語")
  end

  test "deep nesting links each level to its immediate parent" do
    src = "+# a\n  +# b\n    +# c\n      +# d\n"
    [a, b, c, d] = notes(src)
    assert a.parent == nil
    assert b.parent == a.line
    assert c.parent == b.line
    assert d.parent == c.line
  end

  test "a dedent re-parents to the correct ancestor, not the nearest line" do
    src = "+# root\n  +# child\n    +# grandchild\n  +# back to child level\n"
    [root, _child, _gc, back] = notes(src)
    assert back.indent == 2
    assert back.parent == root.line
  end

  # ── sweep: idempotency, collisions, weird text ──────────────────────────────

  test "re-sweeping a file with only handles is a no-op (handles aren't live)" do
    {once, recs} = Sweep.sweep_source("-# collapse me\n", "f.work", %{sweep_sha: "aaa1111"})
    assert length(recs) == 1
    {twice, recs2} = Sweep.sweep_source(once, "f.work", %{sweep_sha: "bbb2222"})
    assert recs2 == []
    assert twice == once
  end

  test "many same-sweep notes get unique suffixed handles (no collision)" do
    src = Enum.map_join(1..5, "\n", &"-# note #{&1}")
    {_new, recs} = Sweep.sweep_source(src, "f.work", %{sweep_sha: "deadbee"})
    hashes = Enum.map(recs, & &1.hash)
    assert length(Enum.uniq(hashes)) == 5
    assert "deadbee" in hashes and "deadbee.1" in hashes and "deadbee.4" in hashes
  end

  test "note text containing ≡ and regex-y chars collapses without corruption" do
    {new, [rec]} = Sweep.sweep_source("-# weird ≡x /a.*b/ \\d+ text\n", "f.work", %{sweep_sha: "c0ffee0"})
    assert rec.text == "weird ≡x /a.*b/ \\d+ text"
    assert new =~ "≡c0ffee0"
  end

  test "empty sweep_sha yields a degenerate-but-safe empty handle" do
    {_new, [rec]} = Sweep.sweep_source("-# x\n", "f.work", %{sweep_sha: ""})
    assert rec.hash == ""
  end

  # ── guard: malformed patterns never crash ───────────────────────────────────

  test "a guard with an invalid regex is skipped, not raised" do
    HashNote.record(%{hash: "g1", text: "#guard broken /[unclosed/", state: :collapsed, polarity: :drawer})
    HashNote.record(%{hash: "g2", text: "#guard ok /System\\.get_env/", state: :collapsed, polarity: :drawer})
    # one valid guard fires; the broken one is silently dropped
    assert [v] = Guard.scan("x = System.get_env(:k)")
    assert v.hash == "g2"
  end

  test "guard scan on empty content is clean" do
    HashNote.record(%{hash: "g", text: "#guard no /x/", state: :collapsed, polarity: :drawer})
    assert Guard.scan("") == []
  end

  # ── dereference / git_ref edge cases ────────────────────────────────────────

  test "git_ref strips every suffix variant" do
    assert HashNote.git_ref("a1b2c3") == "a1b2c3"
    assert HashNote.git_ref("a1b2c3.1") == "a1b2c3"
    assert HashNote.git_ref("a1b2c3.1.2") == "a1b2c3"
  end

  test "expand of an unknown handle with no repo fails cleanly" do
    assert {:error, :not_found} = HashNote.expand("nope999", dir: System.tmp_dir!())
  end
end
