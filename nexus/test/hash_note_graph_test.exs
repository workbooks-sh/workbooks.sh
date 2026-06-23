defmodule Nexus.HashNoteGraphTest do
  use ExUnit.Case, async: false
  alias Nexus.HashNote

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  test "graph proximity surfaces a note on a depended-on unit's file" do
    dir = Path.join(System.tmp_dir!(), "gn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    # :caller depends on [[helper]]; the two units live in different files/dirs.
    File.write!(Path.join(dir, "caller.work"), "server :caller do\n  Helper.go()  # [[helper]]\n  :ok\nend\n")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/helper.work"), "server :helper do\n  :ok\nend\n")
    graph = Nexus.Graph.build_dir(dir)

    # a note anchored to the helper's file
    HashNote.record(%{hash: "n1", file: Path.join(dir, "sub/helper.work"), anchor: 1, text: "helper caution", state: :collapsed, polarity: :drawer})

    # focused on caller.work (different dir from helper) — without graph, helper note is NOT near
    assert HashNote.notes_near(Path.join(dir, "caller.work")) == []
    # with the graph + unit, the depended-on helper's note surfaces
    near = HashNote.notes_near(Path.join(dir, "caller.work"), nil, graph: graph, unit: "caller")
    assert Enum.map(near, & &1.hash) == ["n1"]

    File.rm_rf!(dir)
  end
end
