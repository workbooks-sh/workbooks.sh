defmodule Nexus.Wasm.Gate do
  @moduledoc """
  A bounded concurrency gate for wasm lanes — a monitored counting semaphore, one per named lane,
  with backpressure and **per-tenant fairness**.

  Each holder is a heavy resource: a **compile** holds a 72MB+ compiler module + a 100–500MB working
  set; a **render** holds ~47MB (post-AOT), and an in-process **component** holds its linear memory
  (capped per guest by wb-9jqy). With no limit, a burst of N requests forks/instantiates N holders →
  OS OOM (the BEAM heap stays flat, so it gives no warning — this is exactly the ceiling the
  saturation test found: ~7 concurrent renders on a 1GB host). The gate caps concurrent holders per
  lane and QUEUES the overflow, so **agent count decouples from the memory wall** — a thousand agents
  share a handful of slots instead of OOMing in a synchronized burst.

  Lanes are independent (a render storm can't starve compiles) and sized per host from the `deploy`
  block config — `compile-concurrency` / `render-concurrency` — not env vars. Holders are monitored,
  so a slot held by a process that crashes or is killed (a Task timeout) is reclaimed.

      Nexus.Wasm.Gate.with_slot(:render, tenant, fn -> run_render() end)

  ## Per-tenant fairness (wb-whvy)

  A slot is tagged with the **tenant** that holds it. The gate is **work-conserving** — when a slot
  is free it's granted immediately, so a single active tenant can use the whole lane. Under
  contention (a non-empty wait queue) a freed slot is handed to the **waiting tenant that currently
  holds the FEWEST slots** (max-min fairness, FIFO tie-break). So one tenant bursting N requests can
  no longer starve everyone else: co-resident tenants each get a fair share of the lane the moment
  they ask. `tenant` defaults to `:shared` for in-tree (single-trust-domain) callers.
  """
  use GenServer

  @lanes %{
    compile: {Nexus.Config, :compile_concurrency},
    render: {Nexus.Config, :render_concurrency},
    # `subproc` (wb-3f42) — heavy wasmtime subprocesses spawned from INSIDE a compile (proc-macro
    # servers, build scripts). A SEPARATE lane (distinct semaphore) so bounding their fan-out can't
    # deadlock against the `:compile` slot the caller already holds.
    subproc: {Nexus.Config, :subproc_concurrency}
  }

  # ── API ──────────────────────────────────────────────────────────────────────────────────────
  def child_specs do
    for {lane, _} <- @lanes do
      Supervisor.child_spec({__MODULE__, lane: lane}, id: name(lane))
    end
  end

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    GenServer.start_link(__MODULE__, opts, name: name(lane))
  end

  @doc """
  Run `fun` holding one slot in `lane` on behalf of `tenant`; blocks (queues) until a slot is
  available. Under contention slots are shared fairly across tenants (see the moduledoc). `tenant`
  defaults to `:shared` — a single trust domain that shares the lane without inter-tenant fairness.
  """
  def with_slot(lane, tenant \\ :shared, fun) when is_function(fun, 0) do
    :ok = GenServer.call(name(lane), {:acquire, tenant}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(name(lane), {:release, self()})
    end
  end

  @doc "`%{limit, available, in_use, queued}` for a lane — observability for the capacity dashboard."
  def stats(lane), do: GenServer.call(name(lane), :stats)

  defp name(lane), do: Module.concat(__MODULE__, lane)

  # ── server ───────────────────────────────────────────────────────────────────────────────────
  # holders: %{pid => {ref, tenant}}; waiting: [{from, pid, ref, tenant}] (FIFO order).
  @impl true
  def init(opts) do
    lane = Keyword.fetch!(opts, :lane)
    limit = Keyword.get(opts, :limit) || lane_limit(lane)
    {:ok, %{limit: limit, available: limit, holders: %{}, waiting: []}}
  end

  defp lane_limit(lane) do
    {mod, fun} = Map.fetch!(@lanes, lane)
    apply(mod, fun, [])
  end

  @impl true
  def handle_call({:acquire, tenant}, {pid, _} = from, %{available: a, holders: h, waiting: w} = s) do
    ref = Process.monitor(pid)

    if a > 0 do
      {:reply, :ok, %{s | available: a - 1, holders: Map.put(h, pid, {ref, tenant})}}
    else
      {:noreply, %{s | waiting: w ++ [{from, pid, ref, tenant}]}}
    end
  end

  def handle_call(:stats, _from, %{limit: l, available: a, waiting: w} = s),
    do: {:reply, %{limit: l, available: a, in_use: l - a, queued: length(w)}, s}

  @impl true
  def handle_cast({:release, pid}, %{holders: h} = s) do
    case Map.pop(h, pid) do
      {nil, _} ->
        {:noreply, s}

      {{ref, _tenant}, h2} ->
        Process.demonitor(ref, [:flush])
        {:noreply, hand_off(%{s | holders: h2})}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{holders: h, waiting: w} = s) do
    case Map.get(h, pid) do
      {^ref, _tenant} -> {:noreply, hand_off(%{s | holders: Map.delete(h, pid)})}
      _ -> {:noreply, %{s | waiting: drop_waiter(w, ref)}}
    end
  end

  # Free one slot: hand it to the FAIREST queued caller (the waiting tenant holding the fewest slots),
  # keeping in_use constant — or, if none wait, return it to the pool.
  defp hand_off(%{available: a, holders: h, waiting: w} = s) do
    case pick_fair(w, h) do
      nil ->
        %{s | available: a + 1}

      {{from, pid, ref, tenant}, rest} ->
        GenServer.reply(from, :ok)
        %{s | waiting: rest, holders: Map.put(h, pid, {ref, tenant})}
    end
  end

  # Max-min fairness: among waiters pick the one whose tenant currently holds the fewest slots.
  # Enum.min_by returns the FIRST minimum, so ties break by FIFO position. Returns {entry, rest}.
  defp pick_fair([], _h), do: nil

  defp pick_fair(w, h) do
    counts =
      Enum.reduce(h, %{}, fn {_pid, {_ref, t}}, acc -> Map.update(acc, t, 1, &(&1 + 1)) end)

    best = Enum.min_by(w, fn {_from, _pid, _ref, t} -> Map.get(counts, t, 0) end)
    {best, List.delete(w, best)}
  end

  defp drop_waiter(w, ref), do: Enum.reject(w, fn {_from, _pid, r, _t} -> r == ref end)
end
