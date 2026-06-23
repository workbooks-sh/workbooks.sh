defmodule Nexus.HashNoteTest do
  use ExUnit.Case, async: false

  alias Nexus.HashNote

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  test "the drawer resource compiles from the dogfooded .work shape" do
    mod = HashNote.resource_mod()
    fields = Keyword.keys(Enum.map(mod.__fields__(), fn {k, _} -> {k, nil} end))
    for f <- [:hash, :file, :anchor, :text, :polarity, :state, :parent, :born_at, :swept_at, :author],
        do: assert(f in fields)
    assert {:polarity, {:enum, [:pin, :drawer]}} in mod.__fields__()
    assert {:state, {:enum, [:live, :collapsed]}} in mod.__fields__()
  end

  test "hash/2 is a sweep-sha prefix; index suffixes collisions; git_ref strips the suffix" do
    sha = "a3f9c1284bd"
    assert HashNote.hash(sha) == "a3f9c12"
    assert HashNote.hash(sha, 0) == "a3f9c12"
    assert HashNote.hash(sha, 1) == "a3f9c12.1"
    assert HashNote.hash(sha, 11) == "a3f9c12.b"
    assert HashNote.git_ref("a3f9c12.b") == "a3f9c12"
    assert HashNote.git_ref("a3f9c12") == "a3f9c12"
  end

  test "record + expand round-trips through the hot drawer" do
    h = HashNote.hash("deadbeef00", 0)
    {:ok, _} =
      HashNote.record(%{
        hash: h,
        file: "nexus/lib/toolkit.ex",
        anchor: 42,
        text: "dropped krunvm here — libkrun deadlocked the BEAM",
        polarity: :drawer,
        state: :collapsed
      })

    assert {:ok, note} = HashNote.expand(h)
    assert note.source == :drawer
    assert note.text =~ "krunvm"
    assert note.anchor == 42
  end

  test "nesting: children/1 returns the rolled-up stack under a parent handle" do
    parent = HashNote.hash("cafe000", 0)
    HashNote.record(%{hash: parent, text: "parent decision", state: :collapsed})
    HashNote.record(%{hash: HashNote.hash("cafe000", 1), parent: parent, text: "child A", state: :collapsed})
    HashNote.record(%{hash: HashNote.hash("cafe000", 2), parent: parent, text: "child B", state: :collapsed})

    kids = HashNote.children(parent) |> Enum.map(& &1.text) |> Enum.sort()
    assert kids == ["child A", "child B"]
  end

  test "expand misses cleanly to the git backstop when not in the drawer" do
    # unknown handle, a dir with no such commit → not_found (proves the ladder falls through)
    assert {:error, :not_found} = HashNote.expand("0000000", dir: System.tmp_dir!())
  end
end
