defmodule Nexus.Live do
  @moduledoc """
  Named **live-stream sources** — the Dock channel a workbook `view` unit subscribes to over SSE.

  A producer (e.g. a `fleet` unit brought up by `Nexus.SSR`) registers a named source whose runner
  is `fn params, emit -> … end` — it pushes events by calling `emit.(map)` and returns when the
  stream ends. The served nexus exposes every source at `GET /live/:source?<params>`; the woven
  `view` template opens an `EventSource` on it. Generic: any streaming capability (a fleet, a job, a
  log tail) registers here and any workbook view can bind to it — not swarm-specific.
  """
  @reg {__MODULE__, :sources}

  @doc "Register (or replace) a named live source. `runner` is `fn params_map, emit_fn -> :ok end`."
  def register(name, runner) when is_binary(name) and is_function(runner, 2) do
    :persistent_term.put(@reg, Map.put(sources(), name, runner))
    :ok
  end

  @doc "All registered sources."
  def sources, do: :persistent_term.get(@reg, %{})

  @doc "Run source `name` with `params`, pushing each event through `emit`. Unknown → one error event."
  def run(name, params, emit) when is_function(emit, 1) do
    case Map.get(sources(), name) do
      nil -> emit.(%{type: "error", error: "no live source: #{name}"})
      runner -> runner.(params, emit)
    end
  end
end
