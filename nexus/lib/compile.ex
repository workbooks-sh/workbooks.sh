defmodule Nexus.Compile do
  @moduledoc """
  Route a parsed unit to its artifact — the one place placement becomes execution:

      resource         → an Ash resource          (the database; `Nexus.Resource.Ash`)
      record           → a value shape             (`Nexus.Resource`)
      server           → a native BEAM module      (`Nexus.Unit`)
      client / foreign → a wasm component          (the compilers → `Nexus.Sandbox`)

  Server units are native Elixir — no wasm. Everything else that isn't pure data compiles to
  wasm via OUR compilers (the moat) and runs on wasmex. The compilers are *reused* from the
  existing toolchain when we wire them in; this module just routes and orchestrates.
  """

  @wasm_kinds ~w(client sandbox rust zig c cpp python svelte solid js ts)

  @doc "Compile one parsed `:code` unit to its artifact, tagged by lane."
  def unit(%{type: :code, kind: kind} = node) do
    cond do
      kind == "resource" -> {:ash, Nexus.Resource.Ash.source(node)}
      kind == "record" -> {:shape, Nexus.Resource.fields(node)}
      kind == "server" -> {:beam, Nexus.Unit.compile(node)}
      kind == "rust" -> {:wasm, rust_unit(node)}
      kind in ~w(c cpp) -> {:wasm, c_unit(node)}
      kind in @wasm_kinds -> {:wasm, {:todo, node.lang, node.name}}
      true -> {:skip, kind}
    end
  end

  # A `rust` unit, fully automatic: derive the typed WIT world from its `pub fn` exports AND its
  # `extern "C"` host imports, then run the proven pipeline. `{:ok, component} | {:error, _}`.
  defp rust_unit(%{body: body} = node) do
    case rust_world(node) do
      %{exports: []} -> {:error, :no_exported_fns}
      %{world: world, name: name, exports: exports, imports: imports} ->
        to_component(body, Enum.map(exports, &elem(&1, 0)), world, name, imports != [], crate_deps(body))
    end
  end

  # A `c`/`cpp` unit: derive the WIT world from the C function signatures, compile (clang →
  # reactor, no command machinery), componentize (no WASI adapter needed). `{:ok, comp} | {:error}`.
  defp c_unit(%{name: name, body: body}) do
    exports = c_sigs(body)

    case exports do
      [] ->
        {:error, :no_exported_fns}

      _ ->
        wname = wit_ident(name)
        lines = Enum.map_join(exports, "\n", fn {f, ps, r} -> "  export #{wit_ident(f)}: func(#{ps})#{r};" end)
        world = "package work:#{wname};\n\nworld #{wname} {\n#{lines}\n}\n"
        src = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}.c")
        File.write!(src, body)

        with {:ok, core} <- Nexus.Compilers.C.compile_to_wasm(src, exports: Enum.map(exports, &elem(&1, 0))) do
          c_componentize(core, world, wname)
        end
    end
  end

  # C signatures: `<ret> name(params) {`. Maps C scalar types → WIT.
  @c_wit %{
    "int" => "s32", "long" => "s64", "char" => "s8", "short" => "s16",
    "unsigned" => "u32", "float" => "f32", "double" => "f64", "bool" => "bool"
  }
  defp c_sigs(body) do
    ~r/\b([a-z]\w*)\s+([a-z_]\w*)\s*\(([^)]*)\)\s*\{/
    |> Regex.scan(body)
    |> Enum.map(fn [_, ret, f, params] -> {f, c_params(params), c_ret(ret)} end)
    |> Enum.uniq()
  end

  defp c_params(p) when p in ["", "void"], do: ""

  defp c_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn part ->
      ws = part |> String.trim() |> String.split(~r/\s+/)
      {nm, ty} = {List.last(ws), ws |> Enum.drop(-1) |> List.last()}
      "#{wit_ident(nm)}: #{Map.get(@c_wit, ty, "s32")}"
    end)
  end

  defp c_ret("void"), do: ""
  defp c_ret(t), do: " -> #{Map.get(@c_wit, t, "s32")}"

  defp c_componentize(core, world_text, world) do
    dir = Path.join(System.tmp_dir!(), "nxcz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    wit = Path.join(dir, "w.wit")
    embed = Path.join(dir, "e.wasm")
    comp = Path.join(dir, "c.component.wasm")
    File.write!(wit, world_text)

    with {_, 0} <- System.cmd("wasm-tools", ["component", "embed", wit, core, "--world", world, "-o", embed]),
         {_, 0} <- System.cmd("wasm-tools", ["component", "new", embed, "-o", comp]) do
      {:ok, comp}
    else
      {out, code} -> {:error, {:componentize_failed, code, out}}
    end
  end

  # A unit declares crate deps with a `// deps: libm, regex` header line; the lane fetches +
  # resolves them from crates.io (version-floors handle ceiling-exceeding releases).
  defp crate_deps(body) do
    case Regex.run(~r/\/\/\s*deps:\s*(.+)/, body) do
      [_, list] -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  def unit(_), do: {:skip, :not_a_unit}

  @doc """
  Bring up a whole `.work` folder. The fast tiers come up eagerly — `server`/type units →
  native BEAM modules, `resource` units → live Ash resources; the `wasm` units (rust/…) are
  enumerated as compile-on-demand (each is a real, slow toolchain build via `unit/1`). Returns
  `%{beam, resources, wasm_units}`.
  """
  def workbook(root) do
    units =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn f -> f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) end)

    by_kind = Enum.group_by(units, & &1.kind)

    resources =
      for u <- Map.get(by_kind, "resource", []) do
        {u.name, try_materialize(u)}
      end

    %{
      beam: try_beam(root),
      resources: resources,
      wasm_units: for(u <- Map.get(by_kind, "rust", []), do: u.name)
    }
  end

  defp try_beam(root) do
    Nexus.Unit.compile_workbook(root)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp try_materialize(u) do
    {res, _domain} = Nexus.Resource.Ash.materialize(u)
    {:ok, res}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @adapter "../runtime/build/tools/wasi_snapshot_preview1.command.wasm"

  @doc """
  The wasm lane, proven end-to-end: Rust `source` exporting `fns` → a typed wasm component
  bound to `wit_text`'s `world`. Three steps, no command machinery:

    1. append a keep-alive `main` referencing each fn (mrustc transpiles whole-program FROM main,
       so an unreferenced `pub fn` is never emitted) — `wasm-ld --export` then surfaces them;
    2. compile to a core module via the moat (`Nexus.Compilers.Rust`);
    3. componentize against the GENERATED WIT world (`wasm-tools embed` + `new`).

  Returns `{:ok, component_path}` — runnable on `Nexus.Sandbox`.
  """
  def to_component(source, fns, wit_text, world, has_imports \\ false, deps \\ []) when is_list(fns) do
    dir = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "u.rs")
    File.write!(src, source <> "\n" <> keepalive_main(fns))

    with {:ok, core, _} <-
           Nexus.Compilers.Rust.rust_compile_to_wasm(src, exports: fns, allow_undefined: true, deps: deps) do
      # Host imports: mrustc emits them as `env::<fn>`, but the component model wants world-level
      # imports at `$root`. Rewrite the import module before componentizing (wasmex supplies impls).
      core = if has_imports, do: rewrite_env_to_root(core, dir), else: core
      componentize(core, wit_text, world, dir)
    end
  end

  # Rewrite the core's `env` import module to `$root` (a wat round-trip) so the component model
  # maps host-capability imports to the world's `$root` namespace. (mrustc ignores the
  # #[link(wasm_import_module)] attribute, so we can't set it from source.)
  defp rewrite_env_to_root(core, dir) do
    {wat, 0} = System.cmd("wasm-tools", ["print", core])
    out = Path.join(dir, "rooted.wasm")
    watp = Path.join(dir, "rooted.wat")
    File.write!(watp, String.replace(wat, ~s/(import "env" /, ~s/(import "$root" /))
    {_, 0} = System.cmd("wasm-tools", ["parse", watp, "-o", out])
    out
  end

  # A main that black-box-references each export's address so mrustc emits the symbol (it
  # transpiles whole-program from main; a plain `as *const ()` gets constant-folded away, but
  # black_box defeats the fold). No call → signature-agnostic. `--export` then surfaces it.
  defp keepalive_main(fns) do
    refs = Enum.map_join(fns, " ", &"core::hint::black_box(#{&1} as usize);")
    "fn main() { #{refs} }\n"
  end

  defp componentize(core, wit_text, world, dir) do
    wit = Path.join(dir, "w.wit")
    embed = Path.join(dir, "e.wasm")
    comp = Path.join(dir, "c.component.wasm")
    adapter = Path.expand(@adapter, File.cwd!())
    File.write!(wit, wit_text)

    with {_, 0} <- System.cmd("wasm-tools", ["component", "embed", wit, core, "--world", world, "-o", embed]),
         {_, 0} <- System.cmd("wasm-tools", ["component", "new", embed, "--adapt", "wasi_snapshot_preview1=#{adapter}", "-o", comp]) do
      {:ok, comp}
    else
      {out, code} -> {:error, {:componentize_failed, code, out}}
    end
  end

  # Rust scalar → WIT type. (Records/strings come with the typed-extractor; scalars cover the
  # numeric/bool surface the component ABI lifts directly.)
  @rust_wit %{
    "i8" => "s8", "i16" => "s16", "i32" => "s32", "i64" => "s64",
    "u8" => "u8", "u16" => "u16", "u32" => "u32", "u64" => "u64",
    "f32" => "f32", "f64" => "f64", "bool" => "bool"
  }

  # `pub fn name(params) -> ret { … }` (body) = export;  `fn name(params) -> ret;` (decl, no
  # body, inside an `extern "C"` block) = a host import the Dock supplies.
  @export_re ~r/pub\s+(?:extern\s+"C"\s+)?fn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?\s*\{/
  @import_re ~r/\bfn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?\s*;/

  @doc """
  Derive a typed WIT world from a `rust` unit — `pub fn` bodies become **exports**, `extern "C"`
  declarations become **imports** (host capabilities). No hand-written WIT. Returns
  `%{world, name, exports, imports}` where exports/imports are `{name, params, ret}` tuples.
  """
  def rust_world(%{name: name, body: body}) do
    exports = sigs(@export_re, body)
    imports = sigs(@import_re, body)
    wname = wit_ident(name)

    lines =
      Enum.map(imports, fn {f, ps, r} -> "  import #{wit_ident(f)}: func(#{ps})#{r};" end) ++
        Enum.map(exports, fn {f, ps, r} -> "  export #{wit_ident(f)}: func(#{ps})#{r};" end)

    world = "package work:#{wname};\n\nworld #{wname} {\n#{Enum.join(lines, "\n")}\n}\n"
    %{world: world, name: wname, exports: exports, imports: imports}
  end

  defp sigs(re, body) do
    Regex.scan(re, body)
    |> Enum.map(fn [_, f, params | rest] -> {f, parse_params(params), wit_ret(List.first(rest))} end)
    |> Enum.uniq()
  end

  defp parse_params(""), do: ""

  defp parse_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn p ->
      case String.split(p, ":", parts: 2) do
        [n, t] -> "#{wit_ident(String.trim(n))}: #{wit_type(String.trim(t))}"
        [t] -> wit_type(String.trim(t))
      end
    end)
  end

  defp wit_ret(r) when r in [nil, ""], do: ""
  defp wit_ret(t), do: " -> #{wit_type(t)}"
  defp wit_type(t), do: Map.get(@rust_wit, t, "s32")
  defp wit_ident(s), do: s |> to_string() |> String.downcase() |> String.replace("_", "-")
end
