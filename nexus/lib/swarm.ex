defmodule Nexus.Swarm do
  @moduledoc """
  The Search Swarm demo's orchestration glue — a thin layer over the nexus orchestration primitives.

  Registers a `Nexus.Live` source named `"swarm"` that runs `Nexus.Fleet` (the multi-round agent
  orchestration primitive) for a query and persists each completed run via `Nexus.Sessions`. This is
  the only swarm-specific code that lives in the runtime, and it's pure orchestration (the nexus's
  job). The demo's UI is a **loaded artifact** (`examples/swarm/demo.html`), served by the nexus —
  not engine code, and not authored into the weaver.
  """

  @doc "Register the demo's live fleet source. Called at server boot."
  def register do
    Nexus.Live.register("swarm", fn params, emit ->
      q = params["q"] || ""
      max = int(params["max"], 8)
      rounds = int(params["rounds"], 3)

      result = Nexus.Fleet.run(q, max: max, rounds: rounds, on_event: emit)

      Nexus.Sessions.save(%{
        query: q,
        agents: length(result.findings),
        report: result.report,
        findings: Enum.map(result.findings, &Map.take(&1, [:id, :subtask, :finding]))
      })
    end)
  end

  defp int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> default
    end
  end

  defp int(_, default), do: default
end
