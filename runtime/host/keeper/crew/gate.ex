defmodule Workbooks.Keeper.Crew.Gate do
  @moduledoc """
  The crew's GLOBAL concurrency cap (wb-wc0.2) — a counting semaphore as a tiny
  GenServer. Crew workers run independently and in parallel, but the box (and the
  LLM budget) needs a ceiling: at most `max` agent RUNS execute at once; the rest
  QUEUE here until a slot frees.

  `acquire/0` is a blocking call: it returns `:ok` immediately if a slot is free,
  otherwise the caller is parked (its GenServer.call blocked) until a `release/0`
  hands it the freed slot — FIFO, so no worker starves. The keeper Worker wraps
  each run in `acquire`/`release` (release in an `after`, so a crashed or
  timed-out run always returns its slot — a wedged worker can never deadlock the
  crew).

  `max` defaults to 2 (`WB_CREW_MAX_CONCURRENT` via `Crew`). The singleton keeper
  does NOT use the gate (it is the only runner; its acquire/release are no-ops).
  """
  use GenServer

  # ── public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Take a slot, blocking (queued FIFO) until one is free. `:infinity` timeout —
  a worker that must wait for the box should wait, not crash. Returns :ok.
  """
  def acquire, do: GenServer.call(__MODULE__, :acquire, :infinity)

  @doc "Return a slot; if anyone is queued, hand it straight to the head of the line."
  def release, do: GenServer.cast(__MODULE__, :release)

  # ── server ────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, %{free: Keyword.get(opts, :max, 2), waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, _from, %{free: free} = st) when free > 0 do
    {:reply, :ok, %{st | free: free - 1}}
  end

  # No slot free → park this caller in the FIFO queue (no reply yet).
  def handle_call(:acquire, from, %{waiting: q} = st) do
    {:noreply, %{st | waiting: :queue.in(from, q)}}
  end

  @impl true
  def handle_cast(:release, %{waiting: q} = st) do
    case :queue.out(q) do
      # Someone waiting → hand them the slot directly (free count stays the same,
      # the slot transfers ownership), unblocking their parked call.
      {{:value, from}, q2} ->
        GenServer.reply(from, :ok)
        {:noreply, %{st | waiting: q2}}

      # No one waiting → the slot returns to the free pool.
      {:empty, _} ->
        {:noreply, %{st | free: st.free + 1}}
    end
  end
end
