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

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Enqueue `msg` on (`tenant`, `topic`). :ok | {:error, :revoked | :message_too_large | :rate_limited | :queue_full | :tenant_full}."
  def publish(tenant, topic, msg, opts \\ [])
      when is_binary(tenant) and is_binary(topic) and is_binary(msg) do
    max = Keyword.get(opts, :max_depth, @max_depth)
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
        Agent.get_and_update(agent(), fn state ->
          key = {tenant, topic}
          q = Map.get(state, key, :queue.new())

          cond do
            :queue.len(q) >= max ->
              Workbooks.BrokerAudit.record(:queue, :deny, :queue_full)
              {{:error, :queue_full}, state}

            tenant_total(state, tenant) >= @max_tenant_msgs ->
              Workbooks.BrokerAudit.record(:queue, :deny, :tenant_full)
              {{:error, :tenant_full}, state}

            true ->
              {:ok, Map.put(state, key, :queue.in(msg, q))}
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
        Agent.get_and_update(agent(), fn state ->
          key = {tenant, topic}

          case :queue.out(Map.get(state, key, :queue.new())) do
            {{:value, msg}, q2} -> {{:ok, msg}, Map.put(state, key, q2)}
            {:empty, _} -> {:empty, state}
          end
        end)
    end
  end

  @doc "Current depth of (`tenant`, `topic`)."
  def depth(tenant, topic) when is_binary(tenant) and is_binary(topic) do
    Agent.get(agent(), fn s -> :queue.len(Map.get(s, {tenant, topic}, :queue.new())) end)
  end

  defp rate_denied?(tenant, {max, window}),
    do: Workbooks.RateLimiter.check(tenant, max, window) == {:error, :rate_limited}

  # total messages queued for `tenant` across ALL its topics (counted under the Agent lock)
  defp tenant_total(state, tenant) do
    Enum.reduce(state, 0, fn
      {{^tenant, _topic}, q}, acc -> acc + :queue.len(q)
      _, acc -> acc
    end)
  end

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
