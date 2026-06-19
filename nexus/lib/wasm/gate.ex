defmodule Nexus.Wasm.Gate do
  @moduledoc """
  A bounded concurrency gate for wasm OS-process lanes — a monitored counting semaphore, one per
  named lane, with backpressure.

  Each `wasmtime run` is a heavy OS process: a **compile** holds a 72MB+ compiler module + a
  100–500MB working set; a **render** holds ~47MB (post-AOT). With no limit, a burst of N requests
  forks N processes → OS OOM (the BEAM heap stays flat, so it gives no warning — this is exactly the
  ceiling the saturation test found: ~7 concurrent renders on a 1GB host). The gate caps concurrent
  holders per lane and QUEUES the overflow, so **agent count decouples from the memory wall** — a
  thousand agents share a handful of render slots instead of OOMing in a synchronized burst.

  Lanes are independent (a render storm can't starve compiles) and sized per host from the
  `<work-deploy>` config — `compile-concurrency` / `render-concurrency` — not env vars. Holders are
  monitored, so a slot held by a process that crashes or is killed (a Task timeout) is reclaimed.

      Nexus.Wasm.Gate.with_slot(:render, fn -> run_render() end)
  """
  use GenServer

  @lanes %{
    compile: {Nexus.Config, :compile_concurrency},
    render: {Nexus.Config, :render_concurrency}
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

  @doc "Run `fun` holding one slot in `lane`; blocks (queues) until a slot is available."
  def with_slot(lane, fun) do
    :ok = GenServer.call(name(lane), :acquire, :infinity)

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
  @impl true
  def init(opts) do
    lane = Keyword.fetch!(opts, :lane)
    limit = Keyword.get(opts, :limit) || lane_limit(lane)
    {:ok, %{limit: limit, available: limit, holders: %{}, waiting: :queue.new()}}
  end

  defp lane_limit(lane) do
    {mod, fun} = Map.fetch!(@lanes, lane)
    apply(mod, fun, [])
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
end
