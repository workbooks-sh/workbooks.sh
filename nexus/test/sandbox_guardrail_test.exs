defmodule Nexus.SandboxGuardrailTest do
  use ExUnit.Case, async: true

  # wb-qre6 — the vendor `build_store` fallback yields an UNLIMITED, non-epoch store when a caller omits
  # `:store`/`:store_limits` (a footgun: silent no-cap, no-CPU-deadline guest). Only two nexus modules
  # may instantiate a component, and both build a BOUNDED epoch store via Nexus.Sandbox. If a NEW caller
  # appears, this fails — forcing whoever added it to route through Nexus.Sandbox (or justify the store).

  @vetted ~w(sandbox.ex js_engine.ex)

  test "every Wasmex.Components.start_link caller is a vetted, bounded one" do
    callers =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&String.contains?(File.read!(&1), "Wasmex.Components.start_link"))
      |> Enum.map(&Path.basename/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert callers == Enum.sort(@vetted),
           """
           Unexpected Wasmex.Components.start_link caller(s): #{inspect(callers -- @vetted)}.
           Components MUST be instantiated via Nexus.Sandbox (bounded epoch store) — the raw
           build_store fallback is UNLIMITED + non-epoch. Route through Nexus.Sandbox, then add the
           file to @vetted here.
           """
  end
end
