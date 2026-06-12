defmodule Workbooks.QueueBroker do
  @moduledoc """
  wb-broker INTER-GUEST MESSAGE QUEUE — host-brokered coordination between sandboxed guests. A guest
  `publish`es a message to a per-tenant topic; another guest (or the same one, later) `poll`s and consumes
  it (oldest-first / FIFO). This is how isolated guests hand work to each other — a serving guest enqueues
  jobs, worker guests drain them — WITHOUT shared memory; the host owns the queue.

  Security: per-TENANT isolation (a tenant only sees its own topics), per-queue DEPTH cap (DoS floor), and
  revocation. Backed by a serializing Agent (so publish/poll are atomic — no lost/duplicated messages).
  """
  use Agent

  @max_depth 1_000

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Enqueue `msg` on (`tenant`, `topic`). :ok | {:error, :queue_full | :revoked}."
  def publish(tenant, topic, msg, opts \\ [])
      when is_binary(tenant) and is_binary(topic) and is_binary(msg) do
    max = Keyword.get(opts, :max_depth, @max_depth)

    if Workbooks.Revocation.revoked?(tenant) do
      {:error, :revoked}
    else
      Agent.get_and_update(agent(), fn state ->
        key = {tenant, topic}
        q = Map.get(state, key, :queue.new())

        if :queue.len(q) >= max do
          {{:error, :queue_full}, state}
        else
          {:ok, Map.put(state, key, :queue.in(msg, q))}
        end
      end)
    end
  end

  @doc "Dequeue the oldest message on (`tenant`, `topic`). {:ok, msg} | :empty | {:error, :revoked}."
  def poll(tenant, topic) when is_binary(tenant) and is_binary(topic) do
    if Workbooks.Revocation.revoked?(tenant) do
      {:error, :revoked}
    else
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
