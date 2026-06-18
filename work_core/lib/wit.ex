defmodule WorkCore.Wit do
  @moduledoc """
  §2 — generate a per-unit **WIT world** from the parsed unit: `export`s from the
  AST signature (`Extract.facts` public defs), `import`s from the unit's `grant`s.
  This is the third code-graph feed and the contract you never hand-write — the
  thing the demo's `contract.work` shows once, labelled "generated".

  This is the world *skeleton*: param/return types default to `string` until the
  full `WorkCore.Wit.Types` mapping lands (§2.2 — record/variant/enum/flags from
  the unit's declared structs). A unit with no signature gets the default `run`.
  """

  alias WorkCore.Capabilities
  alias WorkCore.Extract

  # The self-contained host capability interfaces come from the single Dock registry
  # (§3) — so a generated package validates standalone AND §2's imports are the same
  # surface the runtime Dock projects. See `WorkCore.Dock`.

  @doc "Generate the WIT `world` source for a `WorkCore.Literate` :code node."
  def world(%{name: name} = node) when is_binary(name) do
    node = Extract.annotate(node)
    facts = Extract.facts(node)
    types = type_defs(facts, name)
    exports = export_lines(facts.exports)
    exports = if exports == [], do: ["export run: func(input: string) -> string;"], else: exports
    imports =
      node |> grants() |> Enum.map(&Capabilities.grant_import/1) |> Enum.reject(&is_nil/1) |> Enum.map(&"import #{&1};")

    body = (types ++ exports ++ imports) |> Enum.map(&indent/1) |> Enum.join("\n")

    "package work:#{wit_name(name)};\n\nworld #{wit_name(name)} {\n#{body}\n}\n"
  end

  def world(_), do: nil

  @doc """
  The per-file shared `interface types` — the home for file-level declarations a
  unit world *imports* rather than owns: a top-level `@statuses` atom-set (enum) and
  a shared `defmodule …, do: defstruct …` type module (record). Returns nil if a
  file declares no shared types. Takes the `WorkCore.Literate.parse/1` node list.
  """
  def file_interface(nodes) when is_list(nodes) do
    # dedup by WIT name — teaching files re-declare shared types (e.g. several lessons
    # each show `defmodule Lead`); a type may be defined only once in a package.
    enums_kv =
      (for node <- nodes,
           node.type == :decl,
           {:enum, name, atoms} <- WorkCore.Extract.Elixir.decl_types(node),
           do: {name, atoms})
      |> Enum.uniq_by(fn {name, _} -> WorkCore.Wit.Types.wit(name) end)

    record_specs =
      (for node <- nodes,
           node.type == :code,
           node.kind == "defmodule",
           {:record, fields} <- Extract.facts(node).types,
           do: {node.name, fields})
      |> Enum.uniq_by(fn {name, _} -> WorkCore.Wit.Types.wit(name) end)

    records = for {name, fields} <- record_specs, do: WorkCore.Wit.Types.record(name, fields, enums_kv)
    enums = for {name, atoms} <- enums_kv, do: WorkCore.Wit.Types.enum(name, atoms)

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
      nodes = WorkCore.Literate.parse(File.read!(path))
      # a bare `defmodule` is a type module (→ the file interface), not a runnable
      # unit; only placed/runnable kinds get a world.
      worlds =
        for n <- nodes, n.type == :code, n.name, n.kind != "defmodule", into: %{}, do: {n.name, world(n)}

      {path, %{interface: file_interface(nodes), worlds: worlds}}
    end
  end

  @doc """
  Assemble a SELF-CONTAINED, valid WIT package for a file's nodes: the host
  capability interfaces it grants, the shared `interface types`, and a `world` per
  unit (each `use`-ing the file types and importing its host interfaces). This is
  the artifact `wasm-tools` can validate and componentize against (§1).
  """
  def package(nodes, pkg_name \\ "demo", shared \\ nil) do
    nodes = Extract.annotate(nodes)

    units =
      (for n <- nodes, n.type == :code, n.name, n.kind != "defmodule", do: n)
      # two units mapping to the same WIT identifier can't both be top-level worlds
      |> Enum.uniq_by(&WorkCore.Wit.Types.wit(&1.name))

    # `shared` = a workbook-wide {interface, type_names} so a param typed by a record
    # defined in another file still resolves; without it, types are file-scoped.
    {iface, type_names} = shared || {file_interface(nodes), type_names(nodes)}

    caps = units |> Enum.flat_map(&grants/1) |> Enum.uniq() |> Enum.filter(&WorkCore.Capabilities.sandbox_capability?/1)
    host = caps |> Enum.map(&WorkCore.Capabilities.interface_wit/1) |> Enum.join("\n\n")
    worlds = Enum.map(units, &pkg_world(&1, type_names))

    parts = ([host, iface] ++ worlds) |> Enum.reject(&(&1 in [nil, ""]))
    "package work:#{wit_name(pkg_name)};\n\n" <> Enum.join(parts, "\n\n") <> "\n"
  end

  @doc "The workbook-wide shared types: `{interface, type_names}` over every file's type defs."
  def workbook_types(root) do
    all = root |> wb_paths() |> Enum.flat_map(fn p -> WorkCore.Literate.parse(File.read!(p)) end) |> Extract.annotate()
    {file_interface(all), type_names(all)}
  end

  @doc "Emit a self-contained, cross-file-resolved WIT package per file. `%{path => wit}`."
  def packages(root) do
    shared = workbook_types(root)

    for path <- wb_paths(root), into: %{} do
      nodes = WorkCore.Literate.parse(File.read!(path))
      {path, package(nodes, Path.basename(path, ".work"), shared)}
    end
  end

  defp wb_paths(root) do
    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work"))) |> Enum.uniq()
  end

  @doc """
  Materialize the generated WIT to disk: write each file's cross-file-resolved package
  to `<out_dir>/<name>.wit`. This is the §1 handoff — the artifact each compile lane
  embeds into its core module (`wasm-tools component embed <name>.wit core --world <unit>`).
  Returns `{:ok, [written_paths]}`.
  """
  def write_packages(root, out_dir) do
    File.mkdir_p!(out_dir)
    shared = workbook_types(root)

    written =
      for path <- wb_paths(root) do
        pkg = path |> File.read!() |> WorkCore.Literate.parse() |> package(Path.basename(path, ".work"), shared)
        dest = Path.join(out_dir, Path.basename(path, ".work") <> ".wit")
        File.write!(dest, pkg)
        dest
      end

    {:ok, written}
  end

  @doc "Validate a WIT source string with wasm-tools. Returns :ok | {:error, message}."
  def validate(wit) when is_binary(wit) do
    path = Path.join(System.tmp_dir!(), "wbwit_#{System.unique_integer([:positive])}.wit")
    File.write!(path, wit)

    try do
      case System.cmd("wasm-tools", ["component", "wit", path], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        {out, _} -> {:error, out}
      end
    rescue
      e in ErlangError -> {:error, "wasm-tools unavailable: #{inspect(e)}"}
    after
      File.rm(path)
    end
  end

  @doc """
  Bind a unit's **generated world** to its compiled **core module** and produce a
  Component-Model component (§1): `wasm-tools component embed <world> <core>` writes the
  world's component-type into the core, then `component new` lifts it. Returns
  `{:ok, component_path} | {:error, message}`. The core module comes from a compile
  lane (rust/zig/javy/Popcorn); this is the binding step that makes it a component
  against the world we generated, not a hand-written one.
  """
  def componentize(core_wasm, world_wit, world_name, out \\ nil) do
    out = out || core_wasm <> ".component.wasm"
    wit_path = Path.join(System.tmp_dir!(), "wbcz_#{System.unique_integer([:positive])}.wit")
    emb = Path.join(System.tmp_dir!(), "wbcz_#{System.unique_integer([:positive])}.embed.wasm")
    File.write!(wit_path, world_wit)

    try do
      with {_, 0} <-
             System.cmd("wasm-tools", ["component", "embed", wit_path, core_wasm, "--world", wit_name(world_name), "-o", emb], stderr_to_stdout: true),
           {_, 0} <-
             System.cmd("wasm-tools", ["component", "new", emb, "-o", out], stderr_to_stdout: true) do
        {:ok, out}
      else
        {msg, _code} -> {:error, msg}
      end
    rescue
      e in ErlangError -> {:error, "wasm-tools unavailable: #{inspect(e)}"}
    after
      File.rm(wit_path)
      File.rm(emb)
    end
  end

  @doc "Parse the capability names a unit grants — see `WorkCore.Capabilities.grants/1`."
  defdelegate grants(node), to: WorkCore.Capabilities

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
      |> Enum.map(fn {fields, i} -> WorkCore.Wit.Types.record(Enum.at(modules, i) || unit, fields, enums_kv) end)

    enums = for {:enum, name, atoms} <- types, do: WorkCore.Wit.Types.enum(name, atoms)
    variants = for {:variant, name, tags} <- types, do: WorkCore.Wit.Types.variant(name, tags)

    records ++ enums ++ variants
  end

  defp indent(block), do: block |> String.split("\n") |> Enum.map(&("  " <> &1)) |> Enum.join("\n")

  # the file's shared type names (records named after type modules, enums)
  defp type_names(nodes) do
    enums =
      for n <- nodes,
          n.type == :decl,
          {:enum, name, _atoms} <- WorkCore.Extract.Elixir.decl_types(n),
          do: WorkCore.Wit.Types.wit(name)

    records =
      for n <- nodes,
          n.type == :code,
          n.kind == "defmodule",
          {:record, _f} <- Extract.facts(n).types,
          do: WorkCore.Wit.Types.wit(n.name)

    (records ++ enums) |> Enum.uniq()
  end

  # one unit's world inside a package: use only the file types it references,
  # then its typed exports and host-interface imports.
  defp pkg_world(node, type_names) do
    facts = Extract.facts(node)

    # a param whose type isn't defined in THIS file (a cross-file record) degrades to
    # string — the package stays valid; precise cross-file typing is a shared-types
    # follow-on.
    exports = pkg_export_lines(facts.exports, type_names)
    exports = if exports == [], do: ["export run: func(input: string) -> string;"], else: exports

    referenced =
      facts.exports
      |> Enum.flat_map(fn
        {_n, types} when is_list(types) -> types
        _ -> []
      end)
      |> Enum.filter(&(&1 in type_names))
      |> Enum.uniq()

    use_line = if referenced == [], do: [], else: ["use types.{#{Enum.join(referenced, ", ")}};"]

    imports =
      node
      |> grants()
      |> Enum.uniq()
      |> Enum.filter(&WorkCore.Capabilities.sandbox_capability?/1)
      |> Enum.map(&"import #{WorkCore.Capabilities.interface_name(&1)};")

    body = (use_line ++ exports ++ imports) |> Enum.map_join("\n", &("  " <> &1))
    "world #{wit_name(node.name)} {\n#{body}\n}"
  end

  # like export_lines, but param types not defined in this file degrade to string
  defp pkg_export_lines(exports, type_names) do
    Enum.map(exports, fn
      {name, types} when is_list(types) ->
        ps =
          types
          |> Enum.map(&if(&1 in type_names or scalar?(&1), do: &1, else: "string"))
          |> Enum.with_index()
          |> Enum.map_join(", ", fn {t, i} -> "a#{i}: #{t}" end)

        "export #{wit_name(name)}: func(#{ps}) -> string;"

      name ->
        "export #{wit_name(name)}: func() -> string;"
    end)
  end

  defp scalar?(t), do: t in ~w(string bool s8 s16 s32 s64 u8 u16 u32 u64 f32 f64 char)

  defp wit_name(name), do: WorkCore.Wit.Types.wit(name)
end
