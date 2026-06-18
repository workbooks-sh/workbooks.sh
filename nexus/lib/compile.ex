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
      kind in @wasm_kinds -> {:wasm, {:compilers, node.lang, node.name}}
      true -> {:skip, kind}
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
end
