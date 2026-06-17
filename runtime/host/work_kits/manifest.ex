defmodule Workbooks.WorkKits.Manifest do
  @moduledoc """
  The PARSER half of `Workbooks.WorkKits` — plain HTML manifest reading (Floki,
  no kernel) plus the property/role/caption regex readers shared across the kit
  surfaces.

  A work-kit declares ITSELF with a reified TYPE edge (tagging = C):

      <work-ref rel="kit" name="git" prefix="git" version="0.1.0" status="stable"
                cli="git" skill-dir="skills/" tagline="…"/>
      <work-ref rel="needs" to="git>=2.30"/>   ← a dependency edge (has `to`)

  `name` is the kit id; sibling `<work-ref rel="needs" to=…>` refs are the kit's
  requires/deps. The top-level TYPE is a small set of co-occurring FACETS, each a
  `<work-ref rel="…">` with NO `to` attr — `kit` (exports a `<prefix-*>` library —
  the floor), `app` (a launchable leaf), `agent` (carries a brain).
  """

  @doc "Every `<work-ref rel=\"kit\">` node (attrs map + doc body + facet set) in a manifest body."
  def work_toolkit_nodes(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        Floki.find(tree, ~s|work-ref[rel="kit"]:not([to])|)
        |> Enum.map(fn {"work-ref", attrs, _} -> node_of(attrs, tree) end)

      {:error, _} ->
        []
    end
  end

  @doc "The first kit node in a manifest body, or nil."
  def work_toolkit(body) do
    case work_toolkit_nodes(body) do
      [n | _] -> n
      [] -> nil
    end
  end

  @doc "The discovery view of a kit node: `%{id, title, version, cli, status, skill_dir, facets}`."
  def view(%{attrs: a} = node) do
    %{
      id: a["id"],
      title: a["title"],
      version: a["version"],
      cli: a["cli"],
      status: a["status"],
      skill_dir: a["skill-dir"],
      facets: Map.get(node, :facets, MapSet.new(["kit"]))
    }
  end

  # A `<work-ref rel="kit">` map → the node shape. `name` is the id, and sibling
  # `needs` refs synthesize the `requires` string so `parse_requires`
  # (operator/dep classification) is unchanged.
  defp node_of(attrs, tree) when is_list(attrs) do
    a = Map.new(attrs)

    %{
      attrs:
        Map.merge(a, %{
          "id" => a["name"],
          "title" => a["title"] || a["tagline"],
          "requires" => kit_needs(tree)
        }),
      doc: Floki.find(tree, "work-doc") |> Floki.text() |> String.trim(),
      facets: kit_facets(tree)
    }
  end

  # The TYPE facets a manifest asserts: every `<work-ref rel=…>` with NO `to` attr.
  # rel="needs" carries `to` (a dep edge), so it is excluded — it is not a type.
  defp kit_facets(tree) do
    Floki.find(tree, "work-ref:not([to])")
    |> Enum.map(fn {"work-ref", attrs, _} -> Map.new(attrs)["rel"] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
  end

  # The kit's dependency edges: each sibling `<work-ref rel="needs" to=…>`, joined
  # into the same space/comma list `parse_requires` consumes.
  defp kit_needs(tree) do
    Floki.find(tree, ~s|work-ref[rel="needs"][to]|)
    |> Enum.map(fn {"work-ref", attrs, _} -> Map.new(attrs)["to"] end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  # ── Build descriptor ──────────────────────────────────────────────────────

  @doc """
  Parse a manifest body (`<work-ref rel="kit">` HTML) into the build descriptor. Each
  field reads the same-named attribute (`build-src` etc. dash-cased per HTML).
  """
  def parse_descriptor(body) do
    node = work_toolkit(body)

    a = case node do
          %{attrs: attrs} -> attrs
          nil -> %{}
        end

    facets = case node do
               %{facets: f} -> f
               _ -> MapSet.new()
             end

    %{
      facets: facets,
      exec: blank_to_nil(a["exec"]),
      trust: blank_to_nil(a["trust"]) || "first-party",
      build_src: parse_build_src(blank_to_nil(a["build-src"])),
      build_lang: blank_to_nil(a["build-lang"]),
      caps: (a["caps"] || "") |> String.split(),
      cli_bin: blank_to_nil(a["cli"]),
      arg_mode: arg_mode(a["arg-mode"]),
      sha256: blank_to_nil(a["sha256"]),
      wasm_path: blank_to_nil(a["wasm-path"]),
      preopen: blank_to_nil(a["preopen"]),
      author_did: blank_to_nil(a["author-did"]),
      signature: blank_to_nil(a["signature"]),
      cem: blank_to_nil(a["cem"]),
      requires: parse_requires(a["requires"])
    }
  end

  @doc """
  Parse a raw `requires` value into typed `{:cli, tok} | {:dep, name, raw}` tokens
  (nil → []). Reads a kit's sibling `<work-ref rel="needs">` edges into the edge shape
  `Workbooks.WorkKits.Graph.closure/3` consumes.
  """
  def parse_requires(nil), do: []

  def parse_requires(line) do
    line
    |> String.replace(~r/\([^)]*\)/, " ")
    |> String.split([",", " "], trim: true)
    |> Enum.map(&classify_requirement/1)
  end

  @req_op ~r/(>=|<=|>|<|=|~|\^)/

  defp classify_requirement(tok) do
    cond do
      Regex.match?(@req_op, tok) ->
        {:cli, tok}

      String.contains?(tok, "@") ->
        [name | _] = String.split(tok, "@", parts: 2)
        {:dep, name, tok}

      true ->
        {:dep, tok, tok}
    end
  end

  # crate:<name> | git+<url> | path:<dir> | wasm:<url> | archive:<url> → tagged tuple.
  defp parse_build_src(nil), do: nil

  defp parse_build_src(spec) do
    spec = String.trim(spec)

    cond do
      String.starts_with?(spec, "crate:") -> {:crate, String.trim_leading(spec, "crate:")}
      String.starts_with?(spec, "git+") -> {:git, String.trim_leading(spec, "git+")}
      String.starts_with?(spec, "path:") -> {:path, String.trim_leading(spec, "path:")}
      String.starts_with?(spec, "wasm:") -> {:wasm, String.trim_leading(spec, "wasm:")}
      String.starts_with?(spec, "archive:") -> {:archive, String.trim_leading(spec, "archive:")}
      String.starts_with?(spec, "gobuild:") -> {:gobuild, String.trim_leading(spec, "gobuild:")}
      String.starts_with?(spec, "script:") -> {:script, String.trim_leading(spec, "script:")}
      String.starts_with?(spec, "zigbuild:") -> {:zigbuild, String.trim_leading(spec, "zigbuild:")}
      true -> {:unknown, spec}
    end
  end

  defp arg_mode("stdin1"), do: :stdin1
  defp arg_mode("argv"), do: :argv
  defp arg_mode(_), do: :argv

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(s), do: s

  # ── Manifest keyword / property / role / caption readers ───────────────────

  @doc """
  Read a `<work-ref rel="kit">` attribute (dash-cased lowercase) from a toolkit's
  manifest dir. `key` is the legacy UPPER_SNAKE name (TAGLINE/VERSION/…); it maps
  to the HTML attribute (tagline/version/…), with CLI_BIN → cli.
  """
  def manifest_kw(dir, key, manifest_file) do
    with {:ok, body} <- File.read(Path.join(dir, manifest_file)),
         %{attrs: attrs} <- work_toolkit(body) do
      blank_to_nil(attrs[attr_name(key)])
    else
      _ -> nil
    end
  end

  defp attr_name("CLI_BIN"), do: "cli"
  defp attr_name(key), do: key |> String.downcase() |> String.replace("_", "-")

  @doc """
  Read an eval/manifest property `key`. Eval suites are Markdown: a property is a
  list item `- **KEY:** value` (or `- KEY: value`). Toolkit manifests still carry
  `#+KEY:`/`:KEY:` lines, so accept both forms. nil if absent.
  """
  def prop(text, key) do
    md = ~r/^\s*-\s+(?:\*\*#{key}:\*\*|#{key}:)\s*(.+?)\s*$/m
    org = ~r/^\s*:#{key}:\s*(.+?)\s*$/m

    case Regex.run(md, text) || Regex.run(org, text) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  @doc """
  The skill TOC: a Markdown skill's `##` section headings (org `#+CAPTION` →
  `##` in the work-* model). Each heading becomes a "  • <heading>" TOC bullet.
  """
  def captions(body),
    do: Regex.scan(~r/^[ \t]*##[ \t]+(.+?)[ \t]*$/m, body) |> Enum.map(fn [_, c] -> String.trim(c) end)

  @doc "Extract the body of every `:role <role>` block (Markdown `<!-- role: -->` or legacy org)."
  def extract_role_blocks(content, role) do
    # Markdown eval/skill suites tag a fenced block's role with an HTML comment on
    # the line just above it: `<!-- role: eval -->` then a ```lang … ``` block.
    md = ~r/<!--\s*role:\s*#{role}\b[^>]*-->\s*\n```[^\n]*\n(.*?)\n\s*```/s
    # Legacy org manifests: `#+begin_src lang :role eval … #+end_src`.
    org = ~r/#\+begin_src\s+[^\n]*:role\s+#{role}\b[^\n]*\n(.*?)\n\s*#\+end_src/s

    (Regex.scan(md, content) ++ Regex.scan(org, content))
    |> Enum.map(fn [_, body] -> body end)
  end

  @doc "Strip `#+KEY:` manifest lines for the given keys (provenance canonicalization)."
  def strip_manifest_lines(body, keys) do
    re = ~r/^[ \t]*#\+(?:#{Enum.join(keys, "|")}):.*\n?/m
    Regex.replace(re, body, "")
  end
end
