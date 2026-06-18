defmodule Nexus.Lang.Zig do
  @moduledoc """
  The Zig WebAssembly compiler language (zig1 → C → clang). Our zig path (`build-obj -ofmt=c`, the
  bootstrap C backend) is EXPORTS-shaped, so it supports `:component` only — it cannot lower a full
  `pub fn main()` std-I/O program to a `:command` module (use rust/c for CLI toolkits).
  """
  @behaviour Nexus.Lang

  @impl true
  def id, do: "zig"
  @impl true
  def summary, do: "Zig via zig1 → C (exports/component only; no command shape)"
  @impl true
  def shapes, do: [:component]

  @impl true
  def compile(_src, :command, _opts),
    do: {:error, {:zig_command_unsupported, "our zig path is exports-only; author CLI toolkits in rust or c"}}

  def compile(_src, :component, _opts),
    do: {:error, {:component_via_orchestrator, "zig component units compile through Nexus.Compile"}}
end
