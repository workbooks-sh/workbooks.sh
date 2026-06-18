defmodule Nexus.Compile.Gate do
  @moduledoc """
  A bounded concurrency gate for the wasm compile lane. Each unit compile shells `wasmtime run
  <compiler.wasm>` — a heavy OS process (clang/mrustc hold a 72MB+ module + a 100–500MB compile
  working set). With no limit, a burst of N compile requests forks N wasmtime processes → OS OOM on a
  normal machine (the BEAM heap stays flat, so it gives no warning). This gate caps concurrent compiles
  and QUEUES the overflow — backpressure instead of a fork bomb.

  Limit = `WB_COMPILE_CONCURRENCY` (env) or `System.schedulers_online/0` (cores) — so each deployment
  sizes it to its host. A counting semaphore: callers `with_slot/1` block until a slot frees. Holders
  are MONITORED, so a compile that crashes or is killed (e.g. a Task timeout) can't leak its slot.
  """
  use GenServer

  # ── API ──────────────────────────────────────────────────────────────────────────────────────
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run `fun` holding one compile slot; blocks (queues) until a slot is available."
  def with_slot(fun) do
    :ok = GenServer.call(__MODULE__, :acquire, :infinity)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, self()})
    end
  end

  @doc "`%{limit, available, in_use, queued}` — observability for the capacity dashboard."
  def stats, do: GenServer.call(__MODULE__, :stats)

  # ── server ───────────────────────────────────────────────────────────────────────────────────
  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit) || env_limit()
    {:ok, %{limit: limit, available: limit, holders: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, {pid, _} = from, %{available: a, holders: h, waiting: w} = s) do
    ref = Process.monitor(pid)

    if a > 0 do
      {:reply, :ok, %{s | available: a - 1, holders: Map.put(h, pid, ref)}}
    else
      {:noreply, %{s | waiting: :queue.in({from, pid, ref}, w)}}
    end
  end

  def handle_call(:stats, _from, %{limit: l, available: a, waiting: w} = s),
    do: {:reply, %{limit: l, available: a, in_use: l - a, queued: :queue.len(w)}, s}

  @impl true
  def handle_cast({:release, pid}, %{holders: h} = s) do
    case Map.pop(h, pid) do
      {nil, _} ->
        {:noreply, s}

      {ref, h2} ->
        Process.demonitor(ref, [:flush])
        {:noreply, hand_off(%{s | holders: h2})}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{holders: h, waiting: w} = s) do
    if Map.get(h, pid) == ref do
      {:noreply, hand_off(%{s | holders: Map.delete(h, pid)})}
    else
      {:noreply, %{s | waiting: drop_waiter(w, ref)}}
    end
  end

  # Free one slot: hand it to the next queued caller (keeping in_use constant) or return it to the pool.
  defp hand_off(%{available: a, holders: h, waiting: w} = s) do
    case :queue.out(w) do
      {{:value, {from, pid, ref}}, w2} ->
        GenServer.reply(from, :ok)
        %{s | waiting: w2, holders: Map.put(h, pid, ref)}

      {:empty, _} ->
        %{s | available: a + 1}
    end
  end

  defp drop_waiter(w, ref), do: :queue.filter(fn {_from, _pid, r} -> r != ref end, w)

  defp env_limit do
    case System.get_env("WB_COMPILE_CONCURRENCY") do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} when n > 0 -> n
          _ -> System.schedulers_online()
        end

      _ ->
        System.schedulers_online()
    end
  end
end
