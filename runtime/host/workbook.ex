defmodule Workbooks.Workbook do
  @moduledoc """
  HTML-native reader for workbooks. A workbook IS an HTML file built from the
  `work-*` Lit web components (the `workponents/` library). The backend never
  needs a bespoke format or kernel to understand it — it parses the HTML with a
  standard parser (Floki) and reads the `work-*` element tree.

  This replaces the old wasm kernel. The jobs the kernel did map onto plain HTML
  parsing:

    * `parse_headlines/1` — the structure/outline: every `work-*` element flattened
      to `{level, title, status, tags, props, lang, ...}` rows.
    * `tangle_plan/1` — the build plan: find `<work-component>` elements (their
      `lang`/`in`/`out`/`deps`/`uses`/`dir` attributes + text body = source) grouped
      under their `<work-flow>` worlds, so the compiler lane can build them.
    * `validate/1` — basic checks over the parsed component graph.
    * `render/1` — a workbook IS HTML; render is the HTML itself (passthrough). The
      browser + the `work-*` Lit components do the visual rendering.

  No GenServer, no wasm, no host calls — Floki over a binary, pure compute.
  """

  # Reserved attributes carry their own meaning (title/status/tags/build wiring)
  # and so are NOT surfaced as generic "props".
  @reserved ~w(id title status tag assignee lang in out deps uses persist dir
               due scheduled at start end cron repeat)

  @lang_ext %{
    "rust" => ".rs",
    "rs" => ".rs",
    "c" => ".c",
    "zig" => ".zig",
    "javascript" => ".js",
    "js" => ".js",
    "typescript" => ".ts",
    "ts" => ".ts"
  }

  @doc "Extract the Workbook Spec (JSON) from artifact HTML."
  def spec(html) when is_binary(html) do
    case Regex.run(~r/<script id="workbook-spec"[^>]*>(.*?)<\/script>/s, html) do
      [_, json] -> Jason.decode(json)
      _ -> {:error, :no_spec}
    end
  end

  @doc """
  Parse a workbook's HTML → a flat list of `work-*` node rows in document order.
  Each row: `%{"level", "title", "status", "tags", "props", "id", "lang", "in",
  "out", "deps", "uses", "dir"}`. `level` is 1-based depth in the `work-*`
  element tree.
  """
  def parse_headlines(src) when is_binary(src) do
    src
    |> parse_work_nodes()
    |> flatten(1)
    |> Enum.map(&node_row/1)
  end

  @doc "Lint a workbook → list of diagnostics (currently none; kept for parity)."
  def lint(_src), do: []

  @doc """
  Emit the build plan from a workbook: `%{"worlds" => [...]}`. Each top-level
  `<work-flow>` is a world; its descendant `<work-component>` elements are the
  buildable components (source = the element's text body, wiring from its
  attributes). A document with no `<work-flow>` but with bare `<work-component>`
  elements yields a single implicit world so loose components still tangle/build.
  """
  def tangle_plan(src) when is_binary(src) do
    roots = parse_work_nodes(src)

    worlds =
      case top_flows(roots) do
        [] ->
          comps = all_components(roots)
          if comps == [], do: [], else: [build_world(implicit_flow(comps))]

        flows ->
          Enum.map(flows, &build_world/1)
      end

    %{"worlds" => worlds}
  end

  @doc """
  Validate a workbook → list of diagnostics. Checks every `work-component` in a
  `work-flow`: a component must declare a language, and any `in` it consumes must
  have an upstream producer (`out`) in the same flow.
  """
  def validate(src) when is_binary(src) do
    roots = parse_work_nodes(src)

    flows =
      case top_flows(roots) do
        [] ->
          comps = all_components(roots)
          if comps == [], do: [], else: [implicit_flow(comps)]

        fs ->
          fs
      end

    Enum.flat_map(flows, fn flow ->
      comps = comps_of(flow)
      produced = comps |> Enum.map(& &1.out) |> Enum.reject(&is_nil/1) |> MapSet.new()

      Enum.flat_map(comps, fn c ->
        []
        |> then(fn d ->
          if c.lang == nil,
            do: [diag("error", c.name, "component has no source block / language") | d],
            else: d
        end)
        |> then(fn d ->
          if c.inp && not MapSet.member?(produced, c.inp),
            do: [diag("error", c.name, "input `#{c.inp}` has no upstream producer") | d],
            else: d
        end)
      end)
    end)
  end

  @doc "The native file extension for a component language, or nil if unbuildable."
  def lang_ext(lang) when is_binary(lang), do: @lang_ext[String.downcase(lang)]
  def lang_ext(_), do: nil

  # ── HTML → work-* node tree (Floki) ──────────────────────────────────────

  # A node mirrors the old kernel's Node: tag + attrs + body text + children.
  defp parse_work_nodes(src) do
    case Floki.parse_fragment(src) do
      {:ok, tree} -> Enum.flat_map(tree, &to_nodes/1)
      {:error, _} -> []
    end
  end

  # Keep only `work-*` elements as nodes; descend through non-work wrappers so a
  # `work-*` element nested inside plain HTML is still found.
  defp to_nodes({tag, attrs, children}) when is_binary(tag) do
    if String.starts_with?(tag, "work-") do
      [
        %{
          tag: tag,
          attrs: Map.new(attrs),
          body: own_text(children),
          children: Enum.flat_map(children, &to_nodes/1)
        }
      ]
    else
      Enum.flat_map(children, &to_nodes/1)
    end
  end

  defp to_nodes(_), do: []

  # Direct text of an element (its source body), trimmed, excluding child elements.
  defp own_text(children) do
    children
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
    |> String.trim()
  end

  defp flatten(nodes, level) do
    Enum.flat_map(nodes, fn n ->
      [{level, n} | flatten(n.children, level + 1)]
    end)
  end

  # ── Row shape for parse_headlines ────────────────────────────────────────

  defp node_row({level, n}) do
    attrs = n.attrs
    status = attrs["status"] && String.upcase(attrs["status"])

    %{
      "level" => level,
      "title" => attrs["title"] || "",
      "status" => status,
      "state" => status,
      "id" => attrs["id"],
      "tag" => attrs["tag"],
      "tags" => tags_of(attrs),
      "props" => props_of(attrs),
      "lang" => attrs["lang"],
      "in" => attrs["in"],
      "out" => attrs["out"],
      "dir" => attrs["dir"],
      "tagname" => n.tag
    }
  end

  defp tags_of(attrs) do
    case attrs["tag"] do
      t when is_binary(t) -> String.split(t)
      _ -> []
    end
  end

  defp props_of(attrs) do
    attrs
    |> Enum.reject(fn {k, _} -> k in @reserved end)
    |> Map.new(fn {k, v} -> {String.upcase(k), v} end)
  end

  # ── Components + build plan ───────────────────────────────────────────────

  defp component?(n), do: n.tag == "work-component"
  defp flow?(n), do: n.tag == "work-flow"

  # The top-most work-flow in each branch; recursion stops at the first flow.
  defp top_flows(nodes) do
    Enum.flat_map(nodes, fn n ->
      if flow?(n), do: [n], else: top_flows(n.children)
    end)
  end

  # Every work-component anywhere in the tree (for the implicit-world fallback).
  defp all_components(nodes) do
    Enum.flat_map(nodes, fn n ->
      child = all_components(n.children)
      if component?(n), do: [n | child], else: child
    end)
  end

  defp implicit_flow(component_nodes) do
    %{tag: "work-flow", attrs: %{}, body: "", children: component_nodes}
  end

  # A component descriptor read off a work-component element.
  defp comp_of(n) do
    a = n.attrs

    %{
      name: a["title"] || "",
      # `lang` present (even empty) = a declared source block.
      lang: a["lang"],
      deps: list_attr(a, "deps"),
      uses: list_attr(a, "uses"),
      inp: nonempty(a["in"]),
      out: nonempty(a["out"]),
      persist: Map.has_key?(a, "persist"),
      src: n.body,
      dir: nonempty(a["dir"])
    }
  end

  defp comps_of(flow) do
    Enum.flat_map(flow.children, fn n ->
      child = comps_of(n)
      if component?(n), do: [comp_of(n) | child], else: child
    end)
  end

  defp build_world(flow) do
    {comps, subworlds} =
      Enum.reduce(flow.children, {[], []}, fn child, {cs, ws} ->
        cond do
          flow?(child) -> {cs, [build_world(child) | ws]}
          component?(child) -> {[comp_of(child) | cs], ws}
          true -> {cs, ws}
        end
      end)

    comps = Enum.reverse(comps)
    subworlds = Enum.reverse(subworlds)
    {imports, exports, edges} = sig_of(comps)

    %{
      "name" => flow.attrs["title"] || "",
      "schedule" => flow.attrs["cron"] || flow.attrs["scheduled"] || flow.attrs["at"],
      "imports" => imports,
      "exports" => exports,
      "components" => Enum.map(comps, &comp_json/1),
      "edges" => Enum.map(edges, fn {f, t} -> %{"from" => f, "to" => t} end),
      "workflows" => subworlds
    }
  end

  defp sig_of(comps) do
    imports = comps |> Enum.flat_map(& &1.uses) |> Enum.sort() |> Enum.dedup()

    producer =
      Enum.reduce(comps, %{}, fn c, acc ->
        if c.out, do: Map.put(acc, c.out, c.name), else: acc
      end)

    {edges, consumed} =
      Enum.reduce(comps, {[], MapSet.new()}, fn c, {es, cons} ->
        case c.inp && producer[c.inp] do
          nil -> {es, cons}
          from -> {[{from, c.name} | es], MapSet.put(cons, c.inp)}
        end
      end)

    exports =
      comps
      |> Enum.map(& &1.out)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(consumed, &1))
      |> Enum.sort()
      |> Enum.dedup()

    {imports, exports, Enum.reverse(edges)}
  end

  defp comp_json(c) do
    %{
      "name" => c.name,
      "lang" => c.lang,
      "deps" => c.deps,
      "uses" => c.uses,
      "in" => c.inp,
      "out" => c.out,
      "persist" => c.persist,
      "src" => c.src,
      "dir" => c.dir
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp list_attr(attrs, key) do
    case attrs[key] do
      v when is_binary(v) and v != "" ->
        v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp nonempty(v) when is_binary(v) and v != "", do: v
  defp nonempty(_), do: nil

  defp diag(level, scope, msg), do: %{"level" => level, "scope" => scope, "message" => msg}
end
