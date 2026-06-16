defmodule Workbooks.BundleIslandsTest do
  @moduledoc """
  Pins the config-island bijection (docs/WORKBOOK-COMPOSITION-MODEL.md P0):
  a workbook tree ⟷ typed `<work-*>` islands, mapping onto the EXISTING contracts
  (`AgentDef.parse`, `Toolkits.parse_descriptor`) with no new IO.

  Hermetic: the agent leg runs the REAL embedded OQL kernel (pure compute, no
  network/LLM) — same posture as bundle_tangle_test.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Bundle.Islands

  setup_all do
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @agent_org """
  * Analyst :agent:
  :PROPERTIES:
  :ID: analyst
  :MODEL: test/model
  :TOOLKITS: crm glyphs
  :END:
  ** System prompt
  You are an analyst.
  """

  @manifest_org """
  #+TITLE: CRM
  #+EXEC: command
  #+CAPS: net
  #+REQUIRES: glyphs, git>=2.30
  """

  defp tree do
    %{
      "agents/analyst.org" => @agent_org,
      "toolkits/crm/manifest.org" => @manifest_org,
      "report.org" => "* Q3 report\nRevenue is up.\n",
      "data.sqlite" => "SQLite format 3\0binary",
      "build/out.wasm" => <<0, 97, 115, 109>>
    }
  end

  test "index classifies the tree into typed islands (ignoring non-structural files)" do
    by_kind = Islands.index(tree()) |> Map.new(&{&1.kind, &1})

    assert map_size(by_kind) == 4
    refute Map.has_key?(by_kind, :wasm)

    agent = by_kind[:agent]
    assert agent.id == "analyst"
    assert agent.path == "agents/analyst.org"
    assert agent.attrs["model"] == "test/model"
    assert agent.attrs["toolkits"] == "crm glyphs"

    tk = by_kind[:toolkit]
    assert tk.id == "crm"
    assert tk.attrs["exec"] == "command"
    assert tk.attrs["caps"] == "net"
    # REQUIRES preserves order; :dep keeps its bare token, :cli its operator form.
    assert tk.attrs["requires"] == "glyphs git>=2.30"

    assert by_kind[:org].path == "report.org"
    assert by_kind[:vfs].id == "data"
  end

  test "render → parse round-trips the island metadata (the bijection)" do
    idx = Islands.index(tree())
    round = Islands.render(idx) |> Islands.parse()

    norm = fn list ->
      list |> Enum.map(&Map.take(&1, [:kind, :id, :path, :attrs])) |> Enum.sort_by(&{&1.kind, &1.path})
    end

    assert norm.(round) == norm.(idx)
    # rendered islands are src-referenced — no inline bodies leak into the fragment.
    assert Enum.all?(round, &is_nil(&1.body))
  end

  test "rendered fragment is byte-stable (deterministic) for a given index" do
    idx = Islands.index(tree())
    assert Islands.render(idx) == Islands.render(idx)
    # self-closing, src-referenced elements only
    frag = Islands.render(idx)
    assert frag =~ ~s(<work-agent id="analyst" src="agents/analyst.org")
    assert frag =~ ~s(<work-toolkit id="crm" src="toolkits/crm/manifest.org")
    refute frag =~ "</work-"
  end

  test "hand-authored inline islands: parse extracts, materialize writes bodies to the tree" do
    html = """
    <work-org src="notes.org"/>
    <work-agent id="bot" model="x">You are a bot.</work-agent>
    <work-table rows="[]"></work-table>
    """

    islands = Islands.parse(html)
    # the live UI element (<work-table>) is ignored; only config islands surface.
    assert length(islands) == 2

    agent = Enum.find(islands, &(&1.kind == :agent))
    assert agent.id == "bot"
    assert agent.attrs["model"] == "x"
    assert agent.body == "You are a bot."

    # src island = identity (bytes already ride the tree); inline body = written.
    tree = Islands.materialize(islands)
    assert tree["agents/bot.org"] == "You are a bot."
    refute Map.has_key?(tree, "notes.org")
  end

  test "inline body with < survives parse (escaping is reversible)" do
    [island] = Islands.parse("<work-org id=\"snip\">if (x &lt; 3) { y }</work-org>")
    assert island.body == "if (x < 3) { y }"
  end
end
