defmodule Nexus.HashNote.RollupTest do
  use ExUnit.Case, async: false

  alias Nexus.HashNote
  alias Nexus.HashNote.Sweep

  setup do
    Nexus.Store.clear(HashNote.resource_mod())
    :ok
  end

  test "store update path re-keys matched rows in place, preserving order" do
    mod = HashNote.resource_mod()
    HashNote.record(%{hash: "a", text: "one", anchor: 1, state: :collapsed})
    HashNote.record(%{hash: "b", text: "two", anchor: 2, state: :collapsed})

    Nexus.Store.update(mod, %{hash: "b"}, %{parent: "P"})

    rows = Nexus.Store.all(mod) |> Enum.sort_by(& &1.anchor)
    assert Enum.map(rows, & &1.parent) == ["", "P"]
    assert Enum.map(rows, & &1.text) == ["one", "two"]
  end

  test "rollup re-keys children under a new parent and creates the parent row" do
    for h <- ~w(c1 c2 c3), do: HashNote.record(%{hash: h, text: h, state: :collapsed, polarity: :drawer})

    {:ok, parent} = HashNote.rollup(~w(c1 c2 c3), %{hash: "PARENT", state: :collapsed, polarity: :drawer})
    assert parent == "PARENT"

    kids = HashNote.children("PARENT") |> Enum.map(& &1.hash) |> Enum.sort()
    assert kids == ~w(c1 c2 c3)
  end

  test "Sweep.rollup collapses a tall same-indent handle stack into one parent line" do
    for h <- ~w(h0 h1 h2 h3), do: HashNote.record(%{hash: h, text: "t#{h}", state: :collapsed, polarity: :drawer})

    src = """
    intro
    ≡h0 note zero
    ≡h1 note one
    ≡h2 note two
    ≡h3 note three
    outro
    """

    assert {new_src, parent, children} = Sweep.rollup(src, %{sweep_sha: "feed1234beef"})
    assert children == ~w(h0 h1 h2 h3)
    # the four handle lines became one parent line
    assert new_src =~ "≡feed123 rolled up 4 notes"
    refute new_src =~ "≡h2 note two"
    assert new_src =~ "intro"
    assert new_src =~ "outro"
    # children re-keyed in the drawer
    assert HashNote.children(parent) |> Enum.count() == 4
  end

  test "rollup is :none when no run meets the threshold" do
    src = "≡a x\nprose between\n≡b y\n"
    assert Sweep.rollup(src, %{sweep_sha: "abc"}) == :none
  end
end
