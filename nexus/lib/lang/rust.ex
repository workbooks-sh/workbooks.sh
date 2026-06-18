defmodule Nexus.Lang.Rust do
  @moduledoc """
  The Rust WebAssembly compiler language (mrustc → clang → wasm-ld). The command shape is the
  natural one (a plain `fn main()` — the lane already links crt1-command.o); the component shape
  (exports) is orchestrated by `Nexus.Compile` for units.
  """
  @behaviour Nexus.Lang

  @impl true
  def id, do: "rust"
  @impl true
  def summary, do: "Rust via mrustc (crates.io, version-floors)"
  @impl true
  def shapes, do: [:command, :component]

  @impl true
  def compile(src, :command, _opts) do
    case Nexus.Compilers.Rust.rust_compile_to_wasm(src, []) do
      {:ok, wasm, _logs} -> {:ok, wasm}
      {:error, _} = err -> err
    end
  end

  def compile(_src, :component, _opts),
    do: {:error, {:component_via_orchestrator, "rust component units compile through Nexus.Compile (WIT-derived)"}}
end
