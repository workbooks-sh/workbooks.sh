defmodule Nexus.Lang.C do
  @moduledoc "The C WebAssembly compiler language (clang.wasm). Component + command shapes."
  @behaviour Nexus.Lang

  @impl true
  def id, do: "c"
  @impl true
  def summary, do: "C via clang.wasm"
  @impl true
  def shapes, do: [:command, :component]

  @impl true
  def compile(src, :command, opts), do: Nexus.Compilers.C.compile_to_wasm(src, [shape: :command] ++ opts)
  def compile(src, :component, opts), do: Nexus.Compilers.C.compile_to_wasm(src, opts)
end
