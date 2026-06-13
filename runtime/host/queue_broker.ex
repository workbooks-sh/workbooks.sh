defmodule Workbooks.QueueBroker do
  @moduledoc """
  wb-broker INTER-GUEST MESSAGE QUEUE — host-brokered coordination between sandboxed guests. A guest
  `publish`es a message to a per-tenant topic; another guest (or the same one, later) `poll`s and consumes
  it (oldest-first / FIFO). This is how isolated guests hand work to each other — a serving guest enqueues
  jobs, worker guests drain them — WITHOUT shared memory; the host owns the queue.

  Security: per-TENANT isolation (a tenant only sees its own topics) + the DoS cadence — per-message BYTE cap,
  per-topic DEPTH cap, per-TENANT total-message cap (bounds the distinct-topic explosion across the global
  Agent state), per-tenant RATE limit on publish AND poll, and revocation. Backed by a serializing Agent so
  publish/poll are atomic (no lost/duplicated messages, and the byte/count caps are checked under the lock).
  """
  use Agent

  @max_depth 1_000
  # wb-uh5w: a giant single message would otherwise pin unbounded host memory in the global Agent state.
  @max_msg_bytes 256 * 1024
  # wb-uh5w: a guest spraying many DISTINCT topics would otherwise grow the global state without a depth cap
  # ever tripping (each topic stays under @max_depth). Bound a tenant's TOTAL queued messages across topics.
  @max_tenant_msgs 50_000

  # State: %{q: %{{tenant, topic} => :queue}, c: %{tenant => total_msgs}}. The per-tenant running count `c`
  # makes the tenant-total quota check O(1) (incremented on publish, decremented on poll) — the earlier
  # full-state scan was O(total topics) PER PUBLISH under the Agent lock, a self-inflicted DoS (wb self-audit).
  def start_link(_ \\ []), do: Agent.start_link(fn -> %{q: %{}, c: %{}} end, name: __MODULE__)

  @doc "Enqueue `msg` on (`tenant`, `topic`). :ok | {:error, :revoked | :message_too_large | :rate_limited | :queue_full | :tenant_full}."
  def publish(tenant, topic, msg, opts \\ [])
      when is_binary(tenant) and is_binary(topic) and is_binary(msg) do
    max = Keyword.get(opts, :max_depth, @max_depth)
    max_tenant = Keyword.get(opts, :max_tenant_msgs, @max_tenant_msgs)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())

    cond do
      Workbooks.Revocation.revoked?(tenant) ->
        Workbooks.BrokerAudit.record(:queue, :deny, :revoked)
        {:error, :revoked}

      byte_size(msg) > @max_msg_bytes ->
        Workbooks.BrokerAudit.record(:queue, :deny, :message_too_large)
        {:error, :message_too_large}

      rate_denied?(tenant, rate) ->
        Workbooks.BrokerAudit.record(:queue, :deny, :rate_limited)
        {:error, :rate_limited}

      true ->
        Agent.get_and_update(agent(), fn %{q: queues, c: counts} = state ->
          key = {tenant, topic}
          q = Map.get(queues, key, :queue.new())

          cond do
            :queue.len(q) >= max ->
              Workbooks.BrokerAudit.record(:queue, :deny, :queue_full)
              {{:error, :queue_full}, state}

            # O(1): the per-tenant running count, not a full-state scan
            Map.get(counts, tenant, 0) >= max_tenant ->
              Workbooks.BrokerAudit.record(:queue, :deny, :tenant_full)
              {{:error, :tenant_full}, state}

            true ->
              queues = Map.put(queues, key, :queue.in(msg, q))
              counts = Map.update(counts, tenant, 1, &(&1 + 1))
              {:ok, %{state | q: queues, c: counts}}
          end
        end)
    end
  end

  @doc "Dequeue the oldest message on (`tenant`, `topic`). {:ok, msg} | :empty | {:error, :revoked | :rate_limited}."
  def poll(tenant, topic, opts \\ []) when is_binary(tenant) and is_binary(topic) do
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())

    cond do
      Workbooks.Revocation.revoked?(tenant) ->
        Workbooks.BrokerAudit.record(:queue, :deny, :revoked)
        {:error, :revoked}

      rate_denied?(tenant, rate) ->
        Workbooks.BrokerAudit.record(:queue, :deny, :rate_limited)
        {:error, :rate_limited}

      true ->
        Agent.get_and_update(agent(), fn %{q: queues, c: counts} = state ->
          key = {tenant, topic}

          case :queue.out(Map.get(queues, key, :queue.new())) do
            {{:value, msg}, q2} ->
              queues = Map.put(queues, key, q2)
              # decrement the per-tenant count (drop to clamp at 0; prune the entry at 0)
              counts =
                case Map.get(counts, tenant, 0) - 1 do
                  n when n <= 0 -> Map.delete(counts, tenant)
                  n -> Map.put(counts, tenant, n)
                end

              {{:ok, msg}, %{state | q: queues, c: counts}}

            {:empty, _} ->
              {:empty, state}
          end
        end)
    end
  end

  @doc "Current depth of (`tenant`, `topic`)."
  def depth(tenant, topic) when is_binary(tenant) and is_binary(topic) do
    Agent.get(agent(), fn %{q: queues} -> :queue.len(Map.get(queues, {tenant, topic}, :queue.new())) end)
  end

  defp rate_denied?(tenant, {max, window}),
    do: Workbooks.RateLimiter.check(tenant, max, window) == {:error, :rate_limited}

  defp agent do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        __MODULE__

      pid ->
        pid
    end
  end
end
