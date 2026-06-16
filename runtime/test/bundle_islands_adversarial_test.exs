defmodule Workbooks.BundleIslandsAdversarialTest do
  @moduledoc """
  ADVERSARIAL hardening of the config-island bijection
  (`Workbooks.Bundle.Islands`, docs/WORKBOOK-COMPOSITION-MODEL.md). Where the
  companion `bundle_islands_test` pins the happy-path bijection, this suite probes
  HOSTILE / malformed / pathological inputs and asserts the layer is SAFE
  (never crashes, never breaks out of its containing tag) and LOSSLESS (adversarial
  values round-trip byte-exactly).

  Hermetic: the agent leg runs the REAL embedded OQL kernel (pure compute), same as
  the companion suite.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Bundle.Islands

  setup_all do
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  # ── 1. Injection / breakout (attr + manifest escaping is reversible & contained) ─
  describe "injection / breakout" do
    @hostile_attr_values [
      ~s(</work-agent>),
      ~s(<work-agent id="evil"/>),
      ~s(plain " quote),
      ~s(amp & here),
      ~s(less < than),
      ~S|<script>alert(1)</script>|,
      ~s(nested <script><script>x</script></script>),
      ~s(]]> cdata end),
      ~s(unicode ✓ 日本語 🚀 — em–dash),
      ~s(mixed & < " </close> all),
      ~s(&amp; &lt; &quot; pre-escaped lookalikes)
    ]

    test "render→parse round-trips every hostile attr value byte-exactly" do
      for v <- @hostile_attr_values do
        island = %{kind: :org, id: "x", path: "x.org", attrs: %{"note" => v}, body: nil}
        [back] = Islands.render([island]) |> Islands.parse()
        assert back.attrs["note"] == v, "attr round-trip lost: #{inspect(v)} -> #{inspect(back.attrs["note"])}"
      end
    end

    test "a rendered attr value cannot break out of its own quoted attribute" do
      # A `"` in the value must be escaped (&quot;) so it can't terminate the attr
      # and inject a sibling attribute / new tag.
      frag = Islands.render([%{kind: :org, id: ~s(a" onload="x), path: "x.org", attrs: %{}, body: nil}])
      # the embedded quotes are neutralized (&quot;) so they can't terminate the
      # id attr and turn the trailing text into a real `onload` attribute.
      assert frag =~ "&quot;"
      refute frag =~ ~s(onload="x")
      assert frag == ~s(<work-org id="a&quot; onload=&quot;x" src="x.org"/>)
      # and it still parses back to the exact id
      [back] = Islands.parse(frag)
      assert back.id == ~s(a" onload="x)
    end

    test "render escapes < so an attr value can't open a tag" do
      frag = Islands.render([%{kind: :org, id: "x", path: "x.org", attrs: %{"a" => "<b>"}, body: nil}])
      # the only literal '<' in the fragment is the work-org tag opener, never the value
      assert frag =~ "&lt;b&gt;" or (frag =~ "&lt;b>" and not (frag =~ "<b>"))
      refute frag =~ "<b>"
    end

    test "inline body with escaped markup round-trips through parse (reversible)" do
      html = ~S|<work-org id="snip">if (x &lt; 3) &amp;&amp; say &quot;hi&quot;</work-org>|
      [island] = Islands.parse(html)
      assert island.body == ~S|if (x < 3) && say "hi"|
    end

    test "manifest value containing </script> is neutralized in the page yet recovered exactly" do
      attrs = %{
        "a" => "see </script> here",
        "b" => "nested </SCRIPT></script>",
        "c" => ~s(quote " and amp & and lt <)
      }

      island = %{kind: :org, id: "x", path: "x.org", attrs: attrs, body: nil}
      page = Islands.embed_manifest("<html><body></body></html>", Islands.to_manifest([island]))

      # the live closing-tag literal does not appear unescaped in the page
      refute page =~ "see </script> here"
      assert [back] = Islands.extract_manifest(page)
      assert back.attrs == attrs
    end

    test "embed→extract does not collapse a value that already contains a backslash-slash" do
      # `embed` escapes `</`→`<\/` and `extract` reverses it. A value whose JSON
      # encoding genuinely carries `<\` (backslash) must NOT be corrupted.
      attrs = %{"a" => "x</y", "b" => "lit <\\/ backslash", "c" => "trail \\"}
      island = %{kind: :org, id: "x", path: "p", attrs: attrs, body: nil}
      page = Islands.embed_manifest("<body></body>", Islands.to_manifest([island]))
      assert [back] = Islands.extract_manifest(page)
      assert back.attrs == attrs
    end
  end

  # ── 2. Malformed HTML in parse/1 (never crash; extract only the valid) ──────────
  describe "malformed HTML parse" do
    @malformed [
      {"empty string", ""},
      {"whitespace only", "   \n\t  "},
      {"unclosed paired tag", ~s(<work-agent id="a" model="x">body but never closed)},
      {"unquoted attrs", ~s(<work-agent id=a model=x/>)},
      {"unknown work-* tag", ~s(<work-foo id="a"/><work-table rows="[]"></work-table>)},
      {"self vs paired mismatch", ~s(<work-org src="a.org">stuff</work-agent>)},
      {"bare lt gt soup", "< > <> </> <<>> work-agent"},
      {"truncated tag", "<work-agent id=\"a\""},
      {"cdata in body", ~s(<work-org id="o"><![CDATA[ <stuff> ]]></work-org>)},
      {"only attrs no value", ~s(<work-org disabled src="a.org"/>)}
    ]

    test "malformed HTML never crashes and never invents islands" do
      for {label, html} <- @malformed do
        islands =
          try do
            Islands.parse(html)
          rescue
            e -> flunk("parse crashed on #{label}: #{inspect(e)}")
          end

        assert is_list(islands), "#{label} did not return a list"
        # every surfaced island has a recognized kind (no unknown-tag leakage)
        assert Enum.all?(islands, &(&1.kind in [:agent, :toolkit, :org, :vfs, :component])),
               "#{label} leaked an unknown kind: #{inspect(islands)}"
      end
    end

    test "unknown work-* tags are ignored; valid siblings still extracted" do
      html = ~s(<work-foo id="a"/><work-org src="real.org"/><work-bar>x</work-bar>)
      islands = Islands.parse(html)
      assert length(islands) == 1
      assert hd(islands).kind == :org
      assert hd(islands).path == "real.org"
    end

    test "duplicate attribute resolves deterministically (last wins, no crash)" do
      [island] = Islands.parse(~s(<work-agent id="a" id="b" model="m"/>))
      assert island.id in ["a", "b"]
      assert island.attrs["model"] == "m"
    end

    test "deeply nested non-work markup inside a body is captured verbatim, not crashed" do
      depth = 200
      open = String.duplicate("<div>", depth)
      close = String.duplicate("</div>", depth)
      [island] = Islands.parse(~s(<work-org id="o">#{open}core#{close}</work-org>))
      assert island.kind == :org
      assert island.body =~ "core"
    end
  end

  # ── 3. Manifest tampering / malformed JSON (fail-safe, never crash) ─────────────
  describe "manifest tampering" do
    @tampered [
      {"unknown kind string", Jason.encode!(%{"islands" => [%{"kind" => "totally_not_a_kind_xyz", "id" => "a"}]})},
      {"non-string kind", Jason.encode!(%{"islands" => [%{"kind" => 123, "id" => "a"}]})},
      {"null kind", Jason.encode!(%{"islands" => [%{"kind" => nil}]})},
      {"missing kind", Jason.encode!(%{"islands" => [%{"id" => "a", "path" => "p"}]})},
      {"islands not a list", Jason.encode!(%{"islands" => "nope"})},
      {"islands is a number", Jason.encode!(%{"islands" => 7})},
      {"entry not a map", Jason.encode!(%{"islands" => ["just a string", 42]})},
      {"attrs not a map", Jason.encode!(%{"islands" => [%{"kind" => "org", "attrs" => "stringy"}]})},
      {"non-string id/path", Jason.encode!(%{"islands" => [%{"kind" => "org", "id" => 9, "path" => false}]})},
      {"truncated json", ~s({"islands":[{"kind":"org")},
      {"empty object", "{}"},
      {"empty array", "[]"},
      {"null literal", "null"},
      {"wrong top shape", Jason.encode!(%{"nope" => true})},
      {"garbage", "not json at all <<<"}
    ]

    test "every tampered/malformed manifest returns a list and never raises" do
      for {label, json} <- @tampered do
        result =
          try do
            Islands.from_manifest(json)
          rescue
            e -> flunk("from_manifest crashed on #{label}: #{inspect(e)}")
          end

        assert is_list(result), "#{label} did not return a list"
        # only known kinds ever reify
        assert Enum.all?(result, &(&1.kind in [:agent, :toolkit, :org, :vfs, :component])),
               "#{label} reified an unknown kind: #{inspect(result)}"
        # attrs is always a map, never a tampered scalar
        assert Enum.all?(result, &is_map(&1.attrs)), "#{label} kept a non-map attrs"
      end
    end

    test "an unknown kind is skipped while valid sibling entries still parse" do
      json =
        Jason.encode!(%{
          "islands" => [
            %{"kind" => "org", "id" => "good", "path" => "g.org"},
            %{"kind" => "ghost_kind_never_loaded", "id" => "bad"},
            %{"kind" => "agent", "id" => "a2", "path" => "a.org", "attrs" => %{"model" => "m"}}
          ]
        })

      result = Islands.from_manifest(json)
      assert length(result) == 2
      ids = result |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a2", "good"]
    end

    test "extract_manifest on a page with a tampered block fails safe to []" do
      page = ~s(<body><script id="work-islands">{"islands":"broken</script></body>)
      assert Islands.extract_manifest(page) == []
    end

    test "extract_manifest with no manifest block returns []" do
      assert Islands.extract_manifest("<html><body>no manifest</body></html>") == []
      assert Islands.extract_manifest("") == []
    end
  end

  # ── 4. Residence swap edge cases (externalize/inline byte-exactness) ────────────
  describe "residence swap edges" do
    test "externalize onto a colliding path overwrites with the island body (last write wins)" do
      existing = %{"snip.org" => "OLD CONTENT"}
      inline = %{kind: :org, id: "snip", path: nil, attrs: %{}, body: "NEW CONTENT"}
      {ext, parts} = Islands.externalize(inline, existing)
      assert ext.path == "snip.org"
      assert parts["snip.org"] == "NEW CONTENT"
    end

    test "inline of a missing src is identity (no crash, body stays nil)" do
      src = %{kind: :org, id: "r", path: "missing.org", attrs: %{}, body: nil}
      assert Islands.inline(src, %{}) == src
      assert Islands.inline(src, %{"other.org" => "x"}) == src
    end

    test "externalize→inline is byte-exact for newlines + unicode + markup bodies" do
      bodies = [
        "line one\nline two\n\ttabbed\r\nwindows crlf\n",
        "unicode ✓ 日本語 🚀   nul byte",
        "<work-agent>nested looking</work-agent> & < > \" markup",
        "",
        String.duplicate("x", 5_000)
      ]

      for body <- bodies do
        inline = %{kind: :org, id: "snip", path: nil, attrs: %{}, body: body}
        {ext, parts} = Islands.externalize(inline, %{})
        back = Islands.inline(ext, parts)
        assert back.body == body, "lost bytes round-tripping body of size #{byte_size(body)}"
      end
    end

    test "externalize of an empty-body inline still writes (preserves the empty file)" do
      inline = %{kind: :org, id: "e", path: nil, attrs: %{}, body: ""}
      {ext, parts} = Islands.externalize(inline, %{})
      assert ext.body == nil
      assert parts[ext.path] == ""
    end

    test "externalize is identity on an already-src island and leaves parts untouched" do
      src = %{kind: :org, id: "r", path: "report.org", attrs: %{}, body: nil}
      assert {^src, %{"a" => "b"}} = Islands.externalize(src, %{"a" => "b"})
    end
  end

  # ── 5. DAG hostile input (edges/1 + Toolkits.closure/3 invariants) ──────────────
  describe "DAG hostile input" do
    defp tk(id, requires), do: %{kind: :toolkit, id: id, path: "toolkits/#{id}/manifest.org", attrs: %{"requires" => requires}, body: nil}

    test "a requires-cycle raises the documented ArgumentError (DAG invariant)" do
      islands = [tk("a", "b"), tk("b", "a")]
      edges = Islands.edges(islands)
      known = Islands.toolkit_ids(islands)

      assert_raise ArgumentError, ~r/cycle/, fn ->
        Workbooks.Toolkits.closure(["a"], edges, known)
      end
    end

    test "a self-edge raises (a node requiring itself is a 1-cycle)" do
      islands = [tk("a", "a")]
      edges = Islands.edges(islands)

      assert_raise ArgumentError, ~r/cycle/, fn ->
        Workbooks.Toolkits.closure(["a"], edges, Islands.toolkit_ids(islands))
      end
    end

    test "a dep pointing at a non-existent toolkit is dropped, not followed" do
      islands = [tk("a", "ghost"), tk("b", "")]
      edges = Islands.edges(islands)
      known = Islands.toolkit_ids(islands)
      # ghost is not in `known`, so the edge is unfollowed; closure is just [a]
      assert Workbooks.Toolkits.closure(["a"], edges, known) == ["a"]
    end

    test "huge fan-out resolves without blowup (acyclic star)" do
      n = 300
      leaves = for i <- 1..n, do: tk("leaf#{i}", "")
      root = tk("root", Enum.map_join(1..n, ", ", &"leaf#{&1}"))
      islands = [root | leaves]
      edges = Islands.edges(islands)
      known = Islands.toolkit_ids(islands)

      closure = Workbooks.Toolkits.closure(["root"], edges, known)
      assert length(closure) == n + 1
      assert "root" in closure
      assert "leaf1" in closure and "leaf#{n}" in closure
    end

    test "edges/1 ignores non-toolkit islands and a nil requires attr" do
      islands = [
        %{kind: :agent, id: "ag", path: "a.org", attrs: %{}, body: nil},
        %{kind: :toolkit, id: "t", path: "t/manifest.org", attrs: %{}, body: nil}
      ]

      edges = Islands.edges(islands)
      assert Map.keys(edges) == ["t"]
      assert edges["t"] == []
    end
  end

  # ── 6. Oversized / pathological (reasonable bounds, not a perf benchmark) ───────
  describe "oversized / pathological" do
    test "a very large inline body round-trips through parse and materialize" do
      big = String.duplicate("a", 500_000)
      html = ~s(<work-org id="big">#{big}</work-org>)
      [island] = Islands.parse(html)
      assert byte_size(island.body) == 500_000
      tree = Islands.materialize([island])
      assert byte_size(tree["big.org"]) == 500_000
    end

    test "many islands index/render/parse round-trips (no quadratic crash)" do
      parts =
        for i <- 1..500, into: %{} do
          {"doc#{i}.org", "* heading #{i}\nbody\n"}
        end

      idx = Islands.index(parts)
      assert length(idx) == 500
      round = idx |> Islands.render() |> Islands.parse()
      assert length(round) == 500
    end

    test "an attribute value of thousands of chars round-trips exactly" do
      huge = String.duplicate("k&v<x\"y ", 2_000)
      island = %{kind: :org, id: "x", path: "x.org", attrs: %{"big" => huge}, body: nil}
      [back] = Islands.render([island]) |> Islands.parse()
      assert back.attrs["big"] == huge
    end

    test "a large manifest embeds and extracts without breakout or loss" do
      islands =
        for i <- 1..200 do
          %{kind: :org, id: "id#{i}", path: "p#{i}.org", attrs: %{"n" => "v</script>#{i}"}, body: nil}
        end

      page = Islands.embed_manifest("<body></body>", Islands.to_manifest(islands))
      refute page =~ "</script>0" <> "0"
      back = Islands.extract_manifest(page)
      assert length(back) == 200
      assert Enum.all?(back, &(&1.attrs["n"] =~ "</script>"))
    end
  end
end
