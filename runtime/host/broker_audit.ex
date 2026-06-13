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
  # wb-8w8x: the `target` is GUEST-CONTROLLED (the attempted URL/host:port). Stored verbatim in the host-
  # lifetime ring it's a memory-exhaustion vector (128 entries × a multi-MB guest string). Truncate it.
  @max_target_bytes 512

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

    target = truncate_target(target)

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

  defp truncate_target(t) when is_binary(t) and byte_size(t) > @max_target_bytes,
    do: binary_part(t, 0, @max_target_bytes)

  defp truncate_target(t), do: t

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

  # owned by the long-lived Workbooks.BrokerTables process (wb self-audit: a transient caller that creates a
  # named table takes it down on exit, crashing later broker calls).
  defp ring, do: Workbooks.BrokerTables.ensure(@ring, [:named_table, :public, :ordered_set])

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

  defp table, do: Workbooks.BrokerTables.ensure(@table, [:named_table, :public, :set])
end
