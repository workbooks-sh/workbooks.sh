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

  # ── P2: round-trip spike — agent → toolkit → toolkit + org, DAG identical ──────
  describe "P2 round-trip spike (nested composition)" do
    # analyst (agent) → crm (toolkit) → browser (toolkit); crm also pulls a bare
    # CLI pre-flight (git>=2.30) which must NOT become a graph edge.
    @analyst """
    * Analyst :agent:
    :PROPERTIES:
    :ID: analyst
    :MODEL: test/model
    :TOOLKITS: crm
    :END:
    ** System prompt
    Resolve CRM questions.
    """
    @crm "#+EXEC: command\n#+REQUIRES: browser, git>=2.30\n"
    @browser "#+EXEC: command\n#+REQUIRES: net>=1\n"

    defp nested_tree do
      %{
        "agents/analyst.org" => @analyst,
        "toolkits/crm/manifest.org" => @crm,
        "toolkits/browser/manifest.org" => @browser,
        "report.org" => "* Findings\nDone.\n"
      }
    end

    test "the #+REQUIRES DAG resolves identically from the exploded tree and the bundled islands" do
      idx = Islands.index(nested_tree())
      known = Islands.toolkit_ids(idx)

      # Exploded form: edges straight from the island index (built off the manifest files).
      exploded = Workbooks.Toolkits.closure(["crm"], Islands.edges(idx), known)

      # Bundled form: render → parse → rebuild edges from the <work-toolkit requires> attrs.
      bundled_islands = idx |> Islands.render() |> Islands.parse()
      bundled = Workbooks.Toolkits.closure(["crm"], Islands.edges(bundled_islands), Islands.toolkit_ids(bundled_islands))

      assert exploded == bundled
      assert MapSet.new(exploded) == MapSet.new(["crm", "browser"])
      # git>=2.30 is a CLI pre-flight, not a toolkit → never an edge.
      refute "git" in exploded
    end

    test "the agent island carries its declared toolkit, linking into the DAG" do
      idx = Islands.index(nested_tree())
      agent = Enum.find(idx, &(&1.kind == :agent))
      assert agent.id == "analyst"
      assert agent.attrs["toolkits"] == "crm"
      # the agent's declared toolkit is a real node in the resolved graph
      assert "crm" in Islands.toolkit_ids(idx)
    end
  end

  # ── P1: the islands manifest (node table) + inline ⟷ src residence swap ────────
  describe "P1 manifest + residence swap" do
    defp norm(list) do
      list |> Enum.map(&Map.take(&1, [:kind, :id, :path, :attrs])) |> Enum.sort_by(&{&1.kind, &1.path})
    end

    test "manifest round-trips the node table loss-free" do
      idx = Islands.index(tree())
      round = idx |> Islands.to_manifest(tree()) |> Islands.from_manifest()
      assert norm(round) == norm(idx)
    end

    test "manifest carries a content hash per node (integrity)" do
      idx = Islands.index(tree())
      json = Islands.to_manifest(idx, tree())
      assert {:ok, %{"v" => "work-islands/1", "islands" => entries}} = Jason.decode(json)
      assert Enum.all?(entries, &(byte_size(&1["hash"]) == 64))
      assert Enum.all?(entries, &(&1["residence"] == "src"))
    end

    test "embed → extract round-trips through a page (idempotent, </script>-safe)" do
      idx = Islands.index(tree())
      json = Islands.to_manifest(idx, tree())

      html = "<html><body><h1>wb</h1></body></html>"
      page = Islands.embed_manifest(html, json)
      assert page =~ ~s(id="work-islands")
      # idempotent: embedding again replaces, doesn't duplicate
      page2 = Islands.embed_manifest(page, json)
      assert length(Regex.scan(~r/id="work-islands"/, page2)) == 1

      assert norm(Islands.extract_manifest(page2)) == norm(idx)
    end

    test "a manifest value containing </script> cannot break out of the tag" do
      island = %{kind: :org, id: "x", path: "x.org", attrs: %{"note" => "see </script> here"}, body: nil}
      page = Islands.embed_manifest("<body></body>", Islands.to_manifest([island]))
      # the literal closing tag is neutralized in the payload
      refute page =~ "see </script> here"
      assert [back] = Islands.extract_manifest(page)
      assert back.attrs["note"] == "see </script> here"
    end

    test "externalize ⟷ inline is a reversible residence swap" do
      inline = %{kind: :org, id: "snip", path: nil, attrs: %{}, body: "if (x < 3) { y }"}

      {ext, parts} = Islands.externalize(inline, %{})
      assert ext.body == nil
      assert ext.path == "snip.org"
      assert parts["snip.org"] == "if (x < 3) { y }"

      back = Islands.inline(ext, parts)
      assert back.body == "if (x < 3) { y }"
      assert back.path == "snip.org"
    end

    test "externalize is identity on an already-src island; inline is identity with no file" do
      src = %{kind: :org, id: "r", path: "report.org", attrs: %{}, body: nil}
      assert {^src, %{}} = Islands.externalize(src, %{})
      assert Islands.inline(src, %{}) == src
    end
  end

  # ── P3: the lang= handler registry (source ↔ artifact dispatch) ────────────────
  describe "P3 lang handler registry" do
    test "handler_for resolves langs + aliases to the existing lanes; unknown → nil" do
      assert %{ext: ".svelte", lane: :svelte} = Islands.handler_for("svelte")
      assert %{ext: ".rs", lane: :rust} = Islands.handler_for("rust")
      assert Islands.handler_for("rs").lane == :rust
      assert Islands.handler_for("ts").lane == :js
      assert Islands.handler_for("SVELTE").lane == :svelte
      assert Islands.handler_for("cobol") == nil
      assert Islands.handler_for(nil) == nil
    end

    test "a <work-component lang=…> island parses, round-trips, and builds a plan" do
      html = """
      <work-component id="card" lang="svelte" src="lib/Card.svelte"/>
      <work-component id="md" lang="rust" src="lib/md.rs"/>
      <work-component id="mystery" lang="cobol" src="lib/legacy.cob"/>
      """

      islands = Islands.parse(html)
      assert length(Islands.component_islands(islands)) == 3

      card = Enum.find(islands, &(&1.id == "card"))
      assert card.kind == :component
      assert card.attrs["lang"] == "svelte"
      assert card.path == "lib/Card.svelte"

      # manifest round-trip keeps the lang attribute (so bundle can dispatch later)
      back = islands |> Islands.to_manifest() |> Islands.from_manifest()
      assert Enum.find(back, &(&1.id == "card")).attrs["lang"] == "svelte"

      # build_plan resolves the buildable ones and DROPS the unknown lang
      plan = Islands.build_plan(islands)
      assert length(plan) == 2
      langs = Enum.map(plan, fn {i, h} -> {i.attrs["lang"], h.lane} end) |> Enum.sort()
      assert langs == [{"rust", :rust}, {"svelte", :svelte}]
      refute Enum.any?(plan, fn {i, _} -> i.id == "mystery" end)
    end

    test "component islands render as <work-component> (src-referenced)" do
      i = %{kind: :component, id: "card", path: "lib/Card.svelte", attrs: %{"lang" => "svelte"}, body: nil}
      frag = Islands.render([i])
      assert frag =~ ~s(<work-component id="card" src="lib/Card.svelte" lang="svelte"/>)
    end
  end
end
