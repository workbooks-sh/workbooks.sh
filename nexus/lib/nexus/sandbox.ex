defmodule Nexus.Sandbox do
  @moduledoc """
  Run a wasm component on **wasmex** — and that's the whole sandbox.

  We do NOT reinvent isolation, memory/CPU limits, a virtual filesystem, or a capability VM:
  wasmtime (via wasmex) already does all of that *inherently*. So this module is intentionally
  tiny — instantiate a component against its generated WIT world, hand it the host imports the
  `Nexus.Dock` grants, call it. wasmex marshals Elixir ↔ WIT across the boundary.

  The "no native code" system: every unit (rust/zig/c/js/python) is compiled to wasm by OUR
  compilers (the moat — `Nexus.Compile` brings them in) and runs *here*. Nothing executes
  natively; wasmex runs the wasm, the Dock mediates every host call. That's the entire model.

  (wasmex lands as a dep when we first run real wasm — the remote calls below compile as
  warnings until then, keeping `nexus` green while the shape is real.)
  """

  @doc """
  Instantiate a wasm component, wiring the granted capabilities as host imports.
  `caps` is the unit's grants (from `Nexus.Dock`); each becomes a typed host import wasmex calls.
  """
  def start(component_path, caps \\ []) do
    Wasmex.Components.start_link(%{path: component_path, imports: imports_for(caps)})
  end

  @doc "Call an exported function on a running component — wasmex marshals the typed values."
  def call(pid, fun, args, timeout \\ 5_000) do
    Wasmex.Components.call_function(pid, fun, args, timeout)
  end

  # The Dock supplies the host implementation for each granted capability — the one place this
  # layer holds real code (everything else is wasmex). The cap→impl wiring lands with the Dock
  # impls (net/kv/secrets/…); until then this is the seam where they plug in.
  defp imports_for(caps) do
    _ = Enum.filter(caps, &Nexus.Dock.capability?/1)
    %{}
  end
end
