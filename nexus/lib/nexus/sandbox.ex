defmodule Nexus.Sandbox do
  @moduledoc """
  Run a `client`/`foreign` unit's wasm component on **wasmex** (the Component Model). Instantiate
  against its generated WIT world; wasmex marshals Elixir ↔ WIT; the Dock supplies the imports.

  This REPLACES the old instance/isolation/vfs/policy/exec-broker stack — wasmex does the sandbox;
  we just drive it. Minimal seam.

  STATUS: **new** — build thin over wasmex.Components.
  """
  def run(_component, _fun, _args), do: raise("not built — drive wasmex.Components")
end
