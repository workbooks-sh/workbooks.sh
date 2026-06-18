defmodule Workbooks.Wit do
  @moduledoc """
  §2 — generate a per-unit **WIT world** from the parsed unit: `export`s from the
  AST signature (`Extract.facts` public defs), `import`s from the unit's `grant`s.
  This is the third code-graph feed and the contract you never hand-write — the
  thing the demo's `contract.work` shows once, labelled "generated".

  This is the world *skeleton*: param/return types default to `string` until the
  full `Workbooks.Wit.Types` mapping lands (§2.2 — record/variant/enum/flags from
  the unit's declared structs). A unit with no signature gets the default `run`.
  """

  alias Workbooks.Extract

  # grant capability → the host interface it imports across the Dock seam
  @grant_imports %{
    "net" => "host:net/fetch",
    "kv" => "host:kv/store",
    "fs" => "host:fs/files",
    "secrets" => "host:secrets/read",
    "exec" => "host:exec/run",
    "queue" => "host:queue/push",
    "llm" => "host:llm/complete",
    "browse" => "host:browse/fetch"
  }

  @caps Map.keys(@grant_imports) ++ ~w(tcp udp tls posix parallel encode commands)

  @doc "Generate the WIT `world` source for a `Workbooks.Literate` :code node."
  def world(%{name: name} = node) when is_binary(name) do
    facts = Extract.facts(node)
    types = type_defs(facts, name)
    exports = export_lines(facts.exports)
    exports = if exports == [], do: ["export run: func(input: string) -> string;"], else: exports
    imports = node |> grants() |> Enum.map(&grant_import/1) |> Enum.reject(&is_nil/1)

    body = (types ++ exports ++ imports) |> Enum.map(&indent/1) |> Enum.join("\n")

    "package work:#{wit_name(name)};\n\nworld #{wit_name(name)} {\n#{body}\n}\n"
  end

  def world(_), do: nil

  @doc """
  The per-file shared `interface types` — the home for file-level declarations a
  unit world *imports* rather than owns: a top-level `@statuses` atom-set (enum) and
  a shared `defmodule …, do: defstruct …` type module (record). Returns nil if a
  file declares no shared types. Takes the `Workbooks.Literate.parse/1` node list.
  """
  def file_interface(nodes) when is_list(nodes) do
    enums_kv =
      for node <- nodes,
          node.type == :decl,
          {:enum, name, atoms} <- Workbooks.Extract.Elixir.decl_types(node),
          do: {name, atoms}

    records =
      for node <- nodes,
          node.type == :code,
          node.kind == "defmodule",
          {:record, fields} <- Extract.facts(node).types,
          do: Workbooks.Wit.Types.record(node.name, fields, enums_kv)

    enums = for {name, atoms} <- enums_kv, do: Workbooks.Wit.Types.enum(name, atoms)

    case records ++ enums do
      [] -> nil
      defs -> "interface types {\n" <> Enum.map_join(defs, "\n", &indent/1) <> "\n}\n"
    end
  end

  @doc """
  Emit the complete generated WIT for a workbook tree — per file, the shared
  `interface types` plus a `world` for every named unit. This is the artifact the
  weave (§1) hands to `wasm-tools` to componentize each unit; nothing here is
  hand-written. Returns `%{path => %{interface: wit | nil, worlds: %{unit => wit}}}`.
  """
  def emit(root) do
    paths =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()

    for path <- paths, into: %{} do
      nodes = Workbooks.Literate.parse(File.read!(path))
      # a bare `defmodule` is a type module (→ the file interface), not a runnable
      # unit; only placed/runnable kinds get a world.
      worlds =
        for n <- nodes, n.type == :code, n.name, n.kind != "defmodule", into: %{}, do: {n.name, world(n)}

      {path, %{interface: file_interface(nodes), worlds: worlds}}
    end
  end

  @doc "Parse the capability names a unit grants, from its block header."
  def grants(%{header: header}) when is_binary(header) do
    # words inside a `grant[:] [ … ]` bracket (handles `net:` and `:net` forms),
    # plus a bare `grant net`; filtered to known caps so string values don't leak.
    in_bracket =
      case Regex.run(~r/grant:?\s*\[([^\]]*)\]/, header, capture: :all_but_first) do
        [inner] ->
          # keyword form `[net: "x", kv: :y]` → the KEYS are caps (values aren't);
          # atom-list form `[:net, :kv]` → the items are caps.
          if Regex.match?(~r/[a-z]+:/, inner),
            do: Regex.scan(~r/([a-z]+):/, inner) |> Enum.map(&List.last/1),
            else: Regex.scan(~r/:([a-z]+)/, inner) |> Enum.map(&List.last/1)

        _ ->
          []
      end

    bare = Regex.scan(~r/\bgrant\s+([a-z]+)\b/, header) |> Enum.map(&List.last/1)

    (in_bracket ++ bare) |> Enum.filter(&(&1 in @caps)) |> Enum.uniq()
  end

  def grants(_), do: []

  # ── private ──

  defp export_lines(exports) do
    Enum.map(exports, fn
      {name, types} when is_list(types) ->
        "export #{wit_name(name)}: func(#{params(types)}) -> string;"

      name ->
        "export #{wit_name(name)}: func() -> string;"
    end)
  end

  defp params([]), do: ""

  defp params(types) when is_list(types) do
    types |> Enum.with_index() |> Enum.map(fn {t, i} -> "a#{i}: #{t}" end) |> Enum.join(", ")
  end

  # the unit's declared types → WIT defs: records (named after their module) + enums
  defp type_defs(%{types: types}, unit) do
    modules = for {:module, m} <- types, do: m
    enums_kv = for {:enum, name, atoms} <- types, do: {name, atoms}

    records =
      (for {:record, fields} <- types, do: fields)
      |> Enum.with_index()
      |> Enum.map(fn {fields, i} -> Workbooks.Wit.Types.record(Enum.at(modules, i) || unit, fields, enums_kv) end)

    enums = for {:enum, name, atoms} <- types, do: Workbooks.Wit.Types.enum(name, atoms)
    variants = for {:variant, name, tags} <- types, do: Workbooks.Wit.Types.variant(name, tags)

    records ++ enums ++ variants
  end

  defp indent(block), do: block |> String.split("\n") |> Enum.map(&("  " <> &1)) |> Enum.join("\n")

  defp grant_import(cap), do: if(wit = @grant_imports[cap], do: "import #{wit};")

  defp wit_name(name), do: Workbooks.Wit.Types.wit(name)
end
