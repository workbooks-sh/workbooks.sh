defmodule Nexus.Autopoet.Worker do
  @moduledoc """
  The autopoet — one per nexus, a HEARTBEAT-LED actor running SENSE → DECIDE → ACT → LEARN (Autopoiesis
  v2 — wb-a6u3.9). On each beat it senses observed reality (telemetry drift + the self-edit backlog),
  proposes a candidate change for each item, validates it in an isolated scratch (`Eval`), and routes it:

    * **autonomous** (a `managed` target, within ceiling, verdict passes) → ready to FIFO-merge;
    * **human-gated** (a structural-triad touch — grant/ceiling/management, or a frozen/proposed target)
      → notify a human (the `#event → hook → notify` seam); the autopoet never lands it alone;
    * **rejected** (won't parse / impure index) → dropped, with the reason learned.

  Every outcome is written to the knowledge layer (`Knowledge`) — learning is data, the only thing the
  autopoet mutates without a human. The actual edit *proposer* (turn an item into `%{path => new_src}`)
  and the *notify* sink are injectable so the cycle is testable without the LLM brain or a live bus; the
  defaults call the autopoet's agent brain and emit on the bus.

  The heartbeat is OPT-IN (`arm/1`) — a nexus does not run an autonomous editing loop unless a deployment
  explicitly enables it. `cycle/1` runs one beat synchronously and returns a report.
  """

  alias Nexus.Autopoet.{Eval, Knowledge}
  alias Nexus.Telemetry

  @doc """
  Run one heartbeat and return a report `%{sensed, results}`. Options:

    * `:root`     — the workbook tree (default `Nexus.Paths.data_dir/0`)
    * `:requests` — pending self-edit requests (the cloud product supplies open `self_edit` to-dos)
    * `:proposer` — `fn item -> {:ok, %{relpath => new_source}} | :skip` (default: the agent brain)
    * `:notify`   — `fn item, reasons -> any` for human-gated items (default: emit on the bus)
    * `:learn?`   — write outcomes to the knowledge layer (default `true`)
  """
  def cycle(opts \\ []) do
    root = Keyword.get(opts, :root) || Nexus.Paths.data_dir()
    proposer = Keyword.get(opts, :proposer, &default_proposer/1)

    items = sense(opts)
    results = Enum.map(items, &process(&1, root, proposer, opts))

    %{sensed: length(items), results: results}
  end

  @doc "Arm the heartbeat on `Nexus.Scheduler` (OPT-IN). `every` is a duration like \"15m\"."
  def arm(every \\ "15m") do
    Nexus.Scheduler.arm("autopoet.heartbeat", %{every: every}, [%{"run" => "autopoet.cycle"}])
  end

  # ── SENSE ──
  defp sense(opts) do
    concerns =
      Telemetry.concerns(opts)
      |> Enum.map(fn {unit, summary, reasons} -> %{kind: :concern, target: to_string(unit), summary: summary, reasons: reasons} end)

    requests =
      Keyword.get(opts, :requests, [])
      |> Enum.map(fn r -> Map.put(Map.new(r), :kind, :request) end)

    concerns ++ requests
  end

  # ── DECIDE + ACT ──
  defp process(item, root, proposer, opts) do
    case proposer.(item) do
      {:ok, changes} when is_map(changes) and map_size(changes) > 0 ->
        route(item, Eval.validate(root, changes), opts)

      _ ->
        record(item, :skipped, [], opts)
    end
  end

  defp route(item, %{verdict: :fail} = v, opts) do
    reasons = v.parse_errors ++ Map.keys(v.impure_indexes)
    record(item, :rejected, reasons, opts)
  end

  defp route(item, %{autonomy: :human_gated, reasons: reasons}, opts) do
    notify(item, reasons, opts)
    record(item, :escalated, reasons, opts)
  end

  defp route(item, %{autonomy: :autonomous}, opts) do
    # Passes static validation and touches nothing human-gated → ready to FIFO-merge (the apply step is
    # JJ.integrate, performed by the deployment's merge lane after the worker hands off a clean branch).
    record(item, :autonomous_ready, [], opts)
  end

  # ── LEARN ──
  defp record(item, action, reasons, opts) do
    if Keyword.get(opts, :learn?, true) do
      Knowledge.learn("autopoet", "#{action} #{item[:kind]} for #{item[:target]}", lesson_evidence(reasons))
    end

    %{target: item[:target], kind: item[:kind], action: action, reasons: reasons}
  end

  defp lesson_evidence([]), do: nil
  defp lesson_evidence(reasons), do: Enum.map_join(reasons, ",", &inspect/1)

  defp notify(item, reasons, opts) do
    case Keyword.get(opts, :notify) do
      fun when is_function(fun, 2) ->
        fun.(item, reasons)

      _ ->
        Nexus.Events.emit(%{
          kind: "autopoet.escalation",
          actor: "autopoet",
          title: "human sign-off needed for #{item[:target]}",
          target: item[:target],
          reasons: Enum.map(reasons, &inspect/1)
        })
    end
  end

  # Default proposer: hand the item to the autopoet's agent brain (a declared `agent :autopoet`). Returns
  # `:skip` when no brain is registered yet — the cycle still senses, routes nothing, and is harmless.
  defp default_proposer(_item), do: :skip
end
