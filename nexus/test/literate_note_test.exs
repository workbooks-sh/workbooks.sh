defmodule Nexus.LiterateNoteTest do
  use ExUnit.Case, async: true

  alias Nexus.Literate

  defp notes(src), do: src |> Literate.parse() |> Enum.filter(&(&1.type == :note))

  test "+# is a pinned, live note" do
    [n] = notes("+# heads up, the guest shim is next")
    assert n.polarity == :pin
    assert n.state == :live
    assert n.hash == nil
    assert n.text == "heads up, the guest shim is next"
    assert n.parent == nil
  end

  test "-# is a drawered, live note" do
    [n] = notes("-# switched off krunvm here, libkrun deadlocked the BEAM")
    assert n.polarity == :drawer
    assert n.state == :live
    assert n.text == "switched off krunvm here, libkrun deadlocked the BEAM"
  end

  test "≡<hash> is a collapsed handle that carries the sweep-sha + summary" do
    [n] = notes("≡a3f9 why we dropped the JSON sidecar")
    assert n.state == :collapsed
    assert n.polarity == nil
    assert n.hash == "a3f9"
    assert n.text == "why we dropped the JSON sidecar"
  end

  test "notes nest by indentation: children point at the parent's line" do
    src = """
    +# parent decision
      -# child caution one
      -# child caution two
        +# grandchild
    """

    [parent, c1, c2, gc] = notes(src)

    assert parent.indent == 0 and parent.parent == nil
    assert c1.parent == parent.line
    assert c2.parent == parent.line
    assert gc.parent == c2.line
  end

  test "a non-note node ends the nesting run" do
    src = """
    +# first run root
      -# first run child

    prose breaks the run

    +# second run root
    """

    [root1, child1, root2] = notes(src)
    assert child1.parent == root1.line
    # the blank/prose between resets the stack — root2 is a fresh root, not nested
    assert root2.parent == nil
  end

  test "notes do not swallow a following code block" do
    src = """
    -# note above a server unit
    server :api do
      :ok
    end
    """

    nodes = Literate.parse(src)
    assert Enum.any?(nodes, &(&1.type == :note))
    code = Enum.find(nodes, &(&1.type == :code))
    assert code.kind == "server"
    assert code.name == "api"
  end

  test "a real markdown list item is NOT a note" do
    [node] = Literate.parse("- a normal bullet list item")
    assert node.type == :prose
  end

  test "notes carry inline refs from their text" do
    [n] = notes("+# see [[deploy-as-index-tree]] and ping #ops")
    assert "[[deploy-as-index-tree]]" in n.refs
    assert "#ops" in n.refs
  end
end
