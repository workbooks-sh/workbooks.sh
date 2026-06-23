defmodule Nexus.HashNoteRetrievalTest do
  use ExUnit.Case, async: false

  alias Nexus.HashNote

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    HashNote.record(%{hash: "h1", file: "nexus/lib/toolkit.ex", anchor: 10, text: "krunvm deadlock — do not revert", state: :collapsed, polarity: :drawer})
    HashNote.record(%{hash: "h2", file: "nexus/lib/other.ex", anchor: 5, text: "same dir note", state: :collapsed, polarity: :drawer})
    HashNote.record(%{hash: "h3", file: "far/away.ex", anchor: 1, text: "unrelated", state: :collapsed, polarity: :drawer})
    :ok
  end

  test "notes_near ranks exact-file above same-dir and excludes far files" do
    near = HashNote.notes_near("nexus/lib/toolkit.ex")
    hashes = Enum.map(near, & &1.hash)
    assert hashes == ["h1", "h2"]   # exact first, same-dir next, far excluded
  end

  test "preamble briefs the nearby collapsed notes, or nil when none" do
    pre = HashNote.preamble(["nexus/lib/toolkit.ex"])
    assert pre =~ "krunvm deadlock"
    assert pre =~ "work note expand"
    assert HashNote.preamble(["nowhere/nothing.ex"]) == nil
  end
end
