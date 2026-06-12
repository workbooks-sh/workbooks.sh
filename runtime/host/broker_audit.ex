defmodule Workbooks.BrokerAudit do
  @moduledoc """
  wb-broker OBSERVABILITY — the "manageable" leg of the keystone. The brokers log every denial (Logger), but
  logs aren't queryable; this is the metered view. `record/3` bumps atomic ETS counters keyed by
  `{broker, outcome}` and `{broker, outcome, reason}`; `stats/0` returns them. A monitor can poll `stats/0` to
  watch denial rates and alert on anomalies (e.g. a spike in `{:net, :deny, :ssrf}` = a guest probing
  internal targets). Lazy public ETS so it works without supervision; cheap (atomic update_counter).

    Workbooks.BrokerAudit.record(:net, :deny, :ssrf)
    Workbooks.BrokerAudit.stats()  # => %{{:net, :deny} => 3, {:net, :deny, :ssrf} => 3, {:net, :allow} => 12}
  """
  @table :wb_broker_audit
  @ring :wb_broker_audit_ring
  @ring_max 128

  @doc """
  Count one broker outcome and, on a denial, append it to the forensics ring. `broker` e.g.
  :net/:tcp/:udp/:tls/:exec; `outcome` :allow|:deny; `reason` atom|nil; `target` the attempted
  destination (url/host:port) for incident review — what the guest tried to reach.
  """
  def record(broker, outcome, reason \\ nil, target \\ nil) when is_atom(broker) and is_atom(outcome) do
    :ets.update_counter(table(), {broker, outcome}, 1, {{broker, outcome}, 0})

    if reason do
      :ets.update_counter(table(), {broker, outcome, reason}, 1, {{broker, outcome, reason}, 0})
    end

    if outcome == :deny do
      key = System.unique_integer([:monotonic, :positive])
      :ets.insert(ring(), {key, {broker, reason, target, System.system_time(:millisecond)}})
      prune_ring()
    end

    # Standard :telemetry event so external monitors (Prometheus, a SIEM, AppSignal, …) can attach to
    # [:workbooks, :broker, :deny] / [:workbooks, :broker, :allow] without coupling to our ETS internals.
    :telemetry.execute(
      [:workbooks, :broker, outcome],
      %{count: 1},
      %{broker: broker, reason: reason, target: target}
    )

    :ok
  end

  @doc "The most recent `n` denials (newest first): list of {broker, reason, target, timestamp_ms}."
  def recent(n \\ 50) do
    ring()
    |> :ets.tab2list()
    |> Enum.sort_by(fn {k, _} -> k end, :desc)
    |> Enum.take(n)
    |> Enum.map(fn {_, ev} -> ev end)
  end

  defp prune_ring do
    case :ets.info(ring(), :size) do
      n when is_integer(n) and n > @ring_max ->
        case :ets.first(ring()) do
          :"$end_of_table" -> :ok
          oldest -> :ets.delete(ring(), oldest)
        end

        prune_ring()

      _ ->
        :ok
    end
  end

  defp ring do
    case :ets.whereis(@ring) do
      :undefined ->
        try do
          :ets.new(@ring, [:named_table, :public, :ordered_set])
        rescue
          ArgumentError -> :ok
        end

        @ring

      _ ->
        @ring
    end
  end

  @doc "All counters as a map keyed by {broker, outcome} and {broker, outcome, reason}."
  def stats, do: table() |> :ets.tab2list() |> Map.new()

  @doc "Count for one key (e.g. {:net, :deny, :ssrf}), or 0."
  def count(key) do
    case :ets.lookup(table(), key) do
      [{_, c}] -> c
      _ -> 0
    end
  end

  @doc "Total denials across all brokers — a single number to alert on."
  def total_denials do
    table()
    |> :ets.tab2list()
    |> Enum.reduce(0, fn
      {{_broker, :deny}, c}, acc -> acc + c
      _, acc -> acc
    end)
  end

  def reset do
    :ets.delete_all_objects(table())
    :ets.delete_all_objects(ring())
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

        @table

      _ ->
        @table
    end
  end
end
