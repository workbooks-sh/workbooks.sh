defmodule Nexus.Ether.Lane do
  @moduledoc """
  One compute lane: a bounded-concurrency work queue in front of a local model server.

  The whole point of Ether is **resource shape**, not model choice. A Mac has two compute units
  that run in parallel — CPU cores and the (single) GPU — so we model them as two lanes with
  different `slots`:

    * **CPU lane** — `slots = perf cores`: the autoregressive model serves many agents at once.
    * **GPU lane** — `slots = 1`: a diffusion model wants the *whole* GPU per run, so jobs run
      strictly one at a time. Serializing the GPU is a feature: each denoise gets full bandwidth,
      and it leaves the shared memory bus with headroom for the CPU lane (measured contention).

  This is the generic mechanism — one GenServer parameterized by `slots`. Submitted work is a
  zero-arg thunk (typically a `Nexus.Llm.complete/2` call against the lane's local endpoint);
  `submit/3` blocks the caller until its job runs and returns, while other callers queue. Jobs run
  in `Nexus.Ether.Tasks` so a crash never takes down the lane.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Run `fun` on this lane, respecting its slot limit. Blocks until the job completes."
  def submit(lane, fun, timeout \\ 130_000), do: GenServer.call(lane, {:submit, fun}, timeout)

  @doc "Lane stats — running jobs and queue depth."
  def stat(lane), do: GenServer.call(lane, :stat)

  @impl true
  def init(opts),
    do: {:ok, %{slots: opts[:slots] || 1, running: 0, queue: :queue.new(), waiting: %{}}}

  @impl true
  def handle_call({:submit, fun}, from, st),
    do: {:noreply, pump(%{st | queue: :queue.in({from, fun}, st.queue)})}

  def handle_call(:stat, _from, st),
    do: {:reply, %{running: st.running, queued: :queue.len(st.queue), slots: st.slots}, st}

  @impl true
  def handle_info({ref, result}, st), do: {:noreply, finish(ref, result, st)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, st),
    do: {:noreply, finish(ref, {:error, {:crash, reason}}, st)}

  # Reply to the caller whose task `ref` just settled, free its slot, then refill from the queue.
  defp finish(ref, result, st) do
    Process.demonitor(ref, [:flush])

    case Map.pop(st.waiting, ref) do
      {nil, _} -> st
      {from, waiting} ->
        GenServer.reply(from, result)
        pump(%{st | running: st.running - 1, waiting: waiting})
    end
  end

  # Start queued jobs until slots are full.
  defp pump(%{running: r, slots: s} = st) when r >= s, do: st

  defp pump(st) do
    case :queue.out(st.queue) do
      {:empty, _} ->
        st

      {{:value, {from, fun}}, q} ->
        task = Task.Supervisor.async_nolink(Nexus.Ether.Tasks, fun)
        pump(%{st | queue: q, running: st.running + 1, waiting: Map.put(st.waiting, task.ref, from)})
    end
  end
end
