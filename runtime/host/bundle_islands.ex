defmodule Workbooks.Bundle.Islands do
  @moduledoc """
  The declarative config-island layer over the bundle compiler (see
  `docs/WORKBOOK-COMPOSITION-MODEL.md`). A workbook's STRUCTURE is expressed as
  typed `<work-*>` custom elements; this module is the **bijection** between those
  islands and the org/tree the runtime already eats — it adds NO new IO and rewrites
  none of `Workbooks.Bundle`/`AgentDef`/`Toolkits`.

  Two directions:

    * `index/1` + `render/1` — given a workbook tree (`%{"path" => bytes}`, the
      `Bundle.read_tree`/`unpack` shape), classify the structural files into typed
      islands and render them as `<work-*>` elements. Islands are `src=`-referenced:
      the bytes stay in the tree files, so this projection is loss-free by
      construction (the tree is the truth; islands describe it).

    * `parse/1` + `materialize/2` — given hand-authored HTML (the front-door form a
      person or a one-shot model writes), pull the `<work-*>` islands back out and
      materialize any INLINE bodies into tree files. `src=` islands are identity
      (their bytes already live in the tree).

  Island kinds map onto existing contracts:

    | kind      | tag              | maps to                                   |
    |-----------|------------------|-------------------------------------------|
    | `:agent`  | `<work-agent>`   | an `:agent:` org def (`AgentDef.parse/1`) |
    | `:toolkit`| `<work-toolkit>` | a `manifest.org` (`Toolkits.parse_descriptor/1`) |
    | `:org`    | `<work-org>`     | any other `.org` file (prose / literate)  |
    | `:vfs`    | `<work-vfs>`     | the SQLite VFS volume                     |

  An island is `%{kind, id, path, attrs: %{}, body: nil | binary}` — `attrs` are the
  rendered attributes minus the explicit `id`/`src`; `body` is set only for inline
  (non-`src`) islands parsed from hand-authored HTML.
  """

  alias Workbooks.{AgentDef, Toolkits}

  @kind_tag %{
    agent: "work-agent",
    toolkit: "work-toolkit",
    org: "work-org",
    vfs: "work-vfs",
    component: "work-component"
  }
  @tag_kind Map.new(@kind_tag, fn {k, v} -> {v, k} end)

  # A headline carrying the `:agent:` tag — the cheap pre-filter so we only invoke
  # the (kernel-backed) AgentDef.parse on files that are actually agent defs.
  @agent_tag ~r/^\*+\s+.*:agent:\s*$/m
  @sqlite_ext ~r/\.(sqlite3?|db)$/i

  @doc """
  Classify a workbook tree into typed structural islands. Pure over the tree;
  deterministic (sorted by path). Non-structural files (compiled `.wasm`, assets,
  the page html) are ignored — they ride the bundle payload, not the island index.
  """
  @spec index(%{optional(binary) => binary}) :: [map]
  def index(parts) when is_map(parts) do
    parts
    |> Enum.flat_map(fn {path, bytes} -> classify(path, bytes) end)
    |> Enum.sort_by(& &1.path)
  end

  defp classify(path, bytes) do
    cond do
      org?(path) and is_binary(bytes) and Regex.match?(@agent_tag, bytes) ->
        [agent_island(path, bytes)]

      Path.basename(path) == "manifest.org" and is_binary(bytes) ->
        [toolkit_island(path, bytes)]

      org?(path) ->
        [%{kind: :org, id: nil, path: path, attrs: %{}, body: nil}]

      Regex.match?(@sqlite_ext, path) ->
        [%{kind: :vfs, id: vfs_id(path), path: path, attrs: %{}, body: nil}]

      true ->
        []
    end
  end

  defp agent_island(path, bytes) do
    def = AgentDef.parse(bytes)

    attrs =
      %{}
      |> put_attr("model", def.model)
      |> put_attr("toolkits", def.toolkits |> List.wrap() |> Enum.join(" "))
      |> put_attr("tagline", def.tagline)

    %{kind: :agent, id: def.id, path: path, attrs: attrs, body: nil}
  end

  defp toolkit_island(path, bytes) do
    d = Toolkits.parse_descriptor(bytes)
    requires = d.requires |> Enum.map(&require_token/1) |> Enum.join(" ")

    attrs =
      %{}
      |> put_attr("exec", d.exec)
      |> put_attr("requires", requires)
      |> put_attr("caps", d.caps |> Enum.join(" "))
      |> put_attr("trust", d.trust)

    # The toolkit id is its directory name (toolkits/<id>/manifest.org) — the same
    # identity `closure_disk` keys on; the manifest carries no explicit id keyword.
    %{kind: :toolkit, id: Path.dirname(path) |> Path.basename(), path: path, attrs: attrs, body: nil}
  end

  defp require_token({:cli, tok}), do: tok
  defp require_token({:dep, _name, raw}), do: raw

  @doc """
  Build the `closure/3` edge map from a list of islands — toolkit id → its parsed
  `#+REQUIRES` tokens, read back from each `<work-toolkit requires="…">` attr via
  the SAME `Toolkits.parse_requires/1`. So the toolkit DAG resolves identically
  whether the edges come from the exploded manifest files or the bundled islands.
  """
  @spec edges([map]) :: %{optional(binary) => list}
  def edges(islands) do
    islands
    |> Enum.filter(&(&1.kind == :toolkit))
    |> Map.new(fn i -> {i.id, Toolkits.parse_requires(Map.get(i.attrs, "requires"))} end)
  end

  @doc "Toolkit ids present in an island list (the `known` set for `closure/3`)."
  @spec toolkit_ids([map]) :: [binary]
  def toolkit_ids(islands), do: for(%{kind: :toolkit, id: id} <- islands, do: id)

  defp vfs_id(path), do: Path.basename(path) |> String.replace(@sqlite_ext, "")

  @doc """
  Render islands as a deterministic `<work-*>` HTML fragment. `src=`-referenced
  (bodies stay in the tree), self-closing, attributes sorted — so the fragment is
  byte-stable for a given index (a precondition for the lossless round-trip).
  """
  @spec render([map]) :: binary
  def render(islands) do
    islands
    |> Enum.sort_by(&{&1.kind, &1.path})
    |> Enum.map_join("\n", &render_one/1)
  end

  defp render_one(%{kind: kind} = i) do
    tag = Map.fetch!(@kind_tag, kind)

    attrs =
      [{"id", i.id}, {"src", i.path}]
      |> Kernel.++(Enum.sort(Map.to_list(i.attrs)))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map_join("", fn {k, v} -> ~s( #{k}="#{esc(v)}") end)

    "<#{tag}#{attrs}/>"
  end

  @doc """
  Parse `<work-*>` islands out of an HTML fragment (regex-based — the established
  host pattern; no parser dep). Handles self-closing `<work-org src=".."/>` and
  paired `<work-agent ...>inline body</work-agent>` (the body is captured for
  `materialize/2`). Unknown `work-*` tags (live UI elements) are ignored.
  """
  @spec parse(binary) :: [map]
  def parse(html) when is_binary(html) do
    Regex.scan(~r/<(work-[\w-]+)((?:\s+[\w:-]+="[^"]*")*)\s*(?:\/>|>(.*?)<\/\1>)/s, html)
    |> Enum.flat_map(fn
      [_, tag, attr_str | rest] ->
        case Map.get(@tag_kind, tag) do
          nil ->
            []

          kind ->
            attrs = parse_attrs(attr_str)
            body = rest |> List.first() |> nilify_blank()
            {id, attrs} = Map.pop(attrs, "id")
            {src, attrs} = Map.pop(attrs, "src")
            [%{kind: kind, id: id, path: src, attrs: attrs, body: body && unesc(body)}]
        end
    end)
  end

  defp parse_attrs(str) do
    Regex.scan(~r/([\w:-]+)="([^"]*)"/, str)
    |> Map.new(fn [_, k, v] -> {k, unesc(v)} end)
  end

  @doc """
  Materialize parsed islands into a tree (`%{"path" => bytes}`), merging onto
  `parts`. An INLINE island (a `body`, no `src`) writes its body to a derived path;
  a `src=` island is identity (its bytes already ride the tree). The result feeds
  straight back into `Bundle.pack`/`tangle_files` — no new IO here.
  """
  @spec materialize([map], %{optional(binary) => binary}) :: %{optional(binary) => binary}
  def materialize(islands, parts \\ %{}) do
    Enum.reduce(islands, parts, fn island, acc ->
      case island do
        %{body: body, path: path} when is_binary(body) ->
          Map.put(acc, path || derive_path(island), body)

        _ ->
          acc
      end
    end)
  end

  # An inline island with no explicit src gets a conventional path by kind+id.
  defp derive_path(%{kind: :agent, id: id}), do: "agents/#{slug(id)}.org"
  defp derive_path(%{kind: :toolkit, id: id}), do: "toolkits/#{slug(id)}/manifest.org"
  defp derive_path(%{kind: :org, id: id}), do: "#{slug(id) || "doc"}.org"
  defp derive_path(%{kind: :vfs, id: id}), do: "#{slug(id) || "vfs"}.sqlite"

  defp slug(nil), do: nil
  defp slug(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  # ── P1: the islands manifest (node table) + the inline ⟷ src residence swap ──

  @manifest_version "work-islands/1"
  @manifest_re ~r/<script[^>]*id="work-islands"[^>]*>(.*?)<\/script>/s

  @doc """
  Serialize islands as the **node table** — the loss-free manifest that lets
  `unbundle` rebuild the exact element/file for each node. Each entry records
  `kind, id, path, residence (inline|src), attrs` and a `hash` (sha256 of the
  node's bytes — the body for inline, the tree file for src) for integrity.
  `parts` supplies the bytes for the src hash; pass `%{}` when unavailable.
  """
  @spec to_manifest([map], %{optional(binary) => binary}) :: binary
  def to_manifest(islands, parts \\ %{}) do
    %{
      "v" => @manifest_version,
      "islands" =>
        Enum.map(islands, fn i ->
          %{
            "kind" => Atom.to_string(i.kind),
            "id" => i.id,
            "path" => i.path,
            "residence" => residence(i),
            "attrs" => i.attrs,
            "hash" => content_hash(i, parts)
          }
          |> Enum.reject(fn {_k, v} -> v in [nil, %{}] end)
          |> Map.new()
        end)
    }
    |> Jason.encode!()
  end

  @doc "Parse a manifest JSON back into islands (the inverse of `to_manifest/2`)."
  @spec from_manifest(binary) :: [map]
  def from_manifest(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"islands" => list}} ->
        Enum.map(list, fn m ->
          %{
            kind: String.to_existing_atom(m["kind"]),
            id: m["id"],
            path: m["path"],
            attrs: m["attrs"] || %{},
            body: nil
          }
        end)

      _ ->
        []
    end
  end

  defp residence(%{body: b}) when is_binary(b), do: "inline"
  defp residence(_), do: "src"

  defp content_hash(%{body: b}, _parts) when is_binary(b), do: sha(b)
  defp content_hash(%{path: p}, parts) when is_binary(p), do: parts |> Map.get(p) |> sha()
  defp content_hash(_, _), do: nil
  defp sha(nil), do: nil
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Embed the islands manifest into a page as an inert `<script id="work-islands">`
  block (idempotent — replaces any prior one). JSON `</` is escaped so the payload
  cannot break out of the script tag (same posture as the other markers).
  """
  @spec embed_manifest(binary, binary) :: binary
  def embed_manifest(html, manifest_json) do
    safe = String.replace(manifest_json, "</", "<\\/")
    block = ~s(<script type="application/json" id="work-islands">#{safe}</script>)

    cond do
      Regex.match?(@manifest_re, html) -> Regex.replace(@manifest_re, html, block)
      String.contains?(html, "</body>") -> String.replace(html, "</body>", block <> "\n</body>", global: false)
      true -> html <> "\n" <> block
    end
  end

  @doc "Extract islands from a page's `work-islands` manifest block (`[]` if none)."
  @spec extract_manifest(binary) :: [map]
  def extract_manifest(html) when is_binary(html) do
    case Regex.run(@manifest_re, html) do
      [_, json] -> json |> String.replace("<\\/", "</") |> from_manifest()
      _ -> []
    end
  end

  @doc """
  Externalize an INLINE island: write its body to a tree file (its `path` or a
  derived one) and return the now-`src`-referenced island + updated `parts`. A
  src island is returned unchanged. The reverse of `inline/2`.
  """
  @spec externalize(map, %{optional(binary) => binary}) :: {map, %{optional(binary) => binary}}
  def externalize(%{body: body} = i, parts) when is_binary(body) do
    path = i.path || derive_path(i)
    {%{i | path: path, body: nil}, Map.put(parts, path, body)}
  end

  def externalize(i, parts), do: {i, parts}

  @doc """
  Inline a SRC island: pull its file content from `parts` into the element body
  and return the now-inline island. A node with no resolvable file is returned
  unchanged. The reverse of `externalize/2`.
  """
  @spec inline(map, %{optional(binary) => binary}) :: map
  def inline(%{path: path} = i, parts) when is_binary(path) do
    case Map.fetch(parts, path) do
      {:ok, body} -> %{i | body: body}
      :error -> i
    end
  end

  def inline(i, _parts), do: i

  # ── P3: the lang= handler registry (source ↔ artifact, reusing the built lanes) ──

  # Each handler is {ext (the source file extension), lane (the existing build lane
  # in Workbooks.Build/PackageManager / the tangle ext map)}. NO new compiler — this
  # only DISPATCHES a `<work-component lang=…>` island's source to the lane that
  # already exists. Aliases (rs→rust, js→javascript) fold to the canonical lane.
  @handlers %{
    "rust" => %{ext: ".rs", lane: :rust},
    "rs" => %{ext: ".rs", lane: :rust},
    "c" => %{ext: ".c", lane: :c},
    "zig" => %{ext: ".zig", lane: :zig},
    "svelte" => %{ext: ".svelte", lane: :svelte},
    "javascript" => %{ext: ".js", lane: :js},
    "js" => %{ext: ".js", lane: :js},
    "typescript" => %{ext: ".ts", lane: :js},
    "ts" => %{ext: ".ts", lane: :js},
    "go" => %{ext: ".go", lane: :go}
  }

  @doc "The lang→handler registry (the source↔artifact dispatch table). See `@handlers`."
  @spec handlers() :: %{optional(binary) => map}
  def handlers, do: @handlers

  @doc "Resolve a `lang` (or alias) to its handler `%{ext, lane}` — nil if unknown."
  @spec handler_for(binary | nil) :: map | nil
  def handler_for(lang) when is_binary(lang), do: Map.get(@handlers, String.downcase(lang))
  def handler_for(_), do: nil

  @doc "The `<work-component>` islands in a list (the lang'd, buildable nodes)."
  @spec component_islands([map]) :: [map]
  def component_islands(islands), do: Enum.filter(islands, &(&1.kind == :component))

  @doc """
  The build plan for a list of islands: each `<work-component lang=…>` paired with
  its resolved handler — `[{island, handler}]`. This is what `bundle` dispatches to
  the existing compile lanes; an unknown/absent lang drops out (not buildable here).
  """
  @spec build_plan([map]) :: [{map, map}]
  def build_plan(islands) do
    islands
    |> component_islands()
    |> Enum.map(fn i -> {i, handler_for(Map.get(i.attrs, "lang"))} end)
    |> Enum.filter(fn {_i, h} -> h end)
  end

  defp org?(path), do: String.ends_with?(path, ".org")

  defp put_attr(map, _k, nil), do: map
  defp put_attr(map, _k, ""), do: map
  defp put_attr(map, k, v), do: Map.put(map, k, v)

  defp nilify_blank(nil), do: nil
  defp nilify_blank(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp esc(v) do
    v |> to_string() |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;") |> String.replace("<", "&lt;")
  end

  defp unesc(v) do
    v |> String.replace("&lt;", "<") |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&")
  end
end
