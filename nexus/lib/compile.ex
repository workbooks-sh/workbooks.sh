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
      kind in @wasm_kinds -> {:wasm, {:todo, node.lang, node.name}}
      true -> {:skip, kind}
    end
  end

  # A `rust` unit, fully automatic: derive the typed WIT world from its `pub fn` signatures,
  # then run the proven pipeline. Returns `{:ok, component_path} | {:error, _}`.
  defp rust_unit(%{body: body} = node) do
    case rust_world(node) do
      {_world, _name, []} -> {:error, :no_exported_fns}
      {world, world_name, fns} -> to_component(body, fns, world, world_name)
    end
  end

  def unit(_), do: {:skip, :not_a_unit}

  @doc """
  Compile a whole workbook's BEAM tier now (the non-wasm half is fully real). Returns
  `%{compiled, failed}` — the live `server`/type modules. The wasm tier joins when the
  compilers are wired through `unit/1`'s `:wasm` lane.
  """
  def workbook(root), do: Nexus.Unit.compile_workbook(root)

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
  def to_component(source, fns, wit_text, world) when is_list(fns) do
    dir = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "u.rs")
    File.write!(src, source <> "\n" <> keepalive_main(fns))

    with {:ok, core, _} <-
           Nexus.Compilers.Rust.rust_compile_to_wasm(src, exports: fns, allow_undefined: true) do
      componentize(core, wit_text, world, dir)
    end
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

  @doc """
  Derive a typed WIT world from a `rust` unit's `pub fn` signatures (no hand-written WIT).
  Returns `{world_text, world_name, fn_names}`. Pairs with `to_component/4`.
  """
  def rust_world(%{name: name, body: body}) do
    re = ~r/pub\s+(?:extern\s+"C"\s+)?fn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?/

    exports =
      Regex.scan(re, body)
      |> Enum.map(fn [_, fname, params | rest] ->
        {fname, parse_params(params), wit_ret(List.first(rest))}
      end)

    wname = wit_ident(name)
    lines = Enum.map_join(exports, "\n", fn {f, ps, r} -> "  export #{wit_ident(f)}: func(#{ps})#{r};" end)
    world = "package work:#{wname};\n\nworld #{wname} {\n#{lines}\n}\n"
    {world, wname, Enum.map(exports, &elem(&1, 0))}
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
