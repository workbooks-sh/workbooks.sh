defmodule Workbooks.HarnessProc do
  @moduledoc """
  A LONG-LIVED streaming child process for the in-nexus harness (wb-b9xv.11 — the make-or-break).

  Today's brokered exec is BUFFERED one-shot: `child_process.execFileSync -> fetch sentinel -> ExecLoopback
  -> ExecBroker.exec -> stdout-at-end`. A real harness needs a child that LIVES across tool round-trips with
  INCREMENTAL stdout/stderr, a WRITABLE stdin, and exit-code/signal propagation. This GenServer is that
  child: it owns ONE `Workbooks.PackageManager.run_streaming` Port (a registered, sha-pinned wasm CLI driven
  by wasmtime — NO native exec), buffers stdout as it arrives, and lets the loopback drain it incrementally,
  write stdin, observe exit, and KILL it on revocation.

  SECURITY — the broker's spine is preserved, and the streaming surface ADDS a kill-switch:
    * the child is only spawned through `Workbooks.ExecBroker.spawn_stream/4`, which runs the SAME
      default-deny / registered-only / command-scope / depth / concurrency / revocation gate as `exec/4`
      BEFORE this process is started (an ungranted/unknown/revoked principal never reaches here);
    * the concurrency slot is held for the child's WHOLE lifetime (acquired at spawn, released on exit) —
      a long-lived child counts against the per-principal fork-bomb width cap exactly like a buffered exec;
    * `kill/1` (called by revocation) `Port.close`es the in-flight run — a revoked principal's stream dies
      mid-flight, not just on its next request;
    * output is byte-capped (`@max_output`) across the whole stream — an infinite-output guest is bounded.
  """
  use GenServer
  require Logger

  alias Workbooks.PackageManager

  @max_output 8 * 1024 * 1024
  # a child with no drain/stdin/exit activity for this long is reaped (a wedged guest can't pin a slot forever).
  @idle_ms 60_000

  defstruct [
    :port,
    :meta,
    :principal,
    :on_release,
    buf: <<>>,
    sent: 0,
    total: 0,
    exit_status: nil,
    closed: false,
    waiters: []
  ]

  # ── public API ───────────────────────────────────────────────────────────────────────────────

  @doc """
  Start a streaming child for an ALREADY-AUTHORIZED run (the broker gate ran upstream). `opts`:
    * `:wasm` (path) — the registered, sha-verified artifact to run,
    * `:argv` (list), `:dirs` (list), `:run_opts` (timeout/fuel/env),
    * `:principal` — for kill-on-revoke + slot accounting,
    * `:on_release` — a 0-arity fn run when the child exits (releases the broker concurrency slot).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Drain stdout produced SINCE the last drain. Returns `{:ok, chunk, status}` where `status` is `:open`
  (more may come) or `{:exited, code}` (the child is done and this is the final drain). Blocks up to
  `timeout` ms for the FIRST byte if nothing is buffered yet (so a poller sees incremental output without
  busy-spinning), then returns whatever is available. An empty chunk with `:open` means "nothing yet".
  """
  def drain(pid, timeout \\ 5_000), do: GenServer.call(pid, {:drain, timeout}, timeout + 1_000)

  @doc "Write `bytes` to the child's stdin. Returns :ok | {:error, :closed}."
  def write_stdin(pid, bytes) when is_binary(bytes), do: GenServer.call(pid, {:stdin, bytes})

  @doc "Kill the in-flight child (revocation / cap breach). Idempotent."
  def kill(pid), do: GenServer.call(pid, :kill)

  @doc "Snapshot: %{exit_status, total_bytes, closed}."
  def info(pid), do: GenServer.call(pid, :info)

  # ── GenServer ────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    wasm = Keyword.fetch!(opts, :wasm)
    argv = Keyword.get(opts, :argv, [])
    dirs = Keyword.get(opts, :dirs, [])
    run_opts = Keyword.get(opts, :run_opts, [])

    case PackageManager.run_streaming(wasm, argv, dirs, run_opts) do
      {:ok, port, meta} ->
        {:ok,
         %__MODULE__{
           port: port,
           meta: meta,
           principal: Keyword.get(opts, :principal),
           on_release: Keyword.get(opts, :on_release)
         }, @idle_ms}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call({:drain, timeout}, from, st) do
    cond do
      st.sent < byte_size(st.buf) ->
        {:reply, take(st), bump(st), @idle_ms}

      st.closed ->
        {:reply, {:ok, "", {:exited, st.exit_status}}, st, @idle_ms}

      true ->
        # nothing buffered yet and still running — park the caller until the next chunk/exit (incremental
        # delivery without a busy loop). Timeout returns an empty "still open" so the poller can re-drain.
        timer = Process.send_after(self(), {:drain_timeout, from}, timeout)
        {:noreply, %{st | waiters: [{from, timer} | st.waiters]}}
    end
  end

  def handle_call({:stdin, _bytes}, _from, %{closed: true} = st),
    do: {:reply, {:error, :closed}, st, @idle_ms}

  def handle_call({:stdin, bytes}, _from, st) do
    Port.command(st.port, bytes)
    {:reply, :ok, st, @idle_ms}
  end

  def handle_call(:kill, _from, st), do: {:stop, :normal, :ok, close_port(st)}

  def handle_call(:info, _from, st) do
    {:reply, %{exit_status: st.exit_status, total_bytes: st.total, closed: st.closed}, st, @idle_ms}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = st) do
    total = st.total + byte_size(chunk)

    # whole-stream output cap: stop accepting bytes past @max_output and kill the guest (a runaway emitter
    # can't OOM the host through the stream). The bytes already buffered are still drainable.
    if total > @max_output do
      Logger.warning("harness-proc: output cap exceeded (#{total} > #{@max_output}) — killing stream")
      st = %{st | buf: st.buf <> binary_part(chunk, 0, max(0, @max_output - st.total)), total: @max_output}
      {:noreply, notify(close_port(st)), @idle_ms}
    else
      {:noreply, notify(%{st | buf: st.buf <> chunk, total: total}), @idle_ms}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = st) do
    {:noreply, notify(%{st | exit_status: code, closed: true, port: nil} |> release()), @idle_ms}
  end

  def handle_info({:drain_timeout, from}, st) do
    case List.keytake(st.waiters, from, 0) do
      {{^from, _timer}, rest} ->
        GenServer.reply(from, {:ok, "", :open})
        {:noreply, %{st | waiters: rest}, @idle_ms}

      nil ->
        {:noreply, st, @idle_ms}
    end
  end

  def handle_info(:timeout, st) do
    Logger.debug("harness-proc idle-reaped")
    {:stop, :normal, close_port(st)}
  end

  def handle_info(_other, st), do: {:noreply, st, @idle_ms}

  @impl true
  def terminate(_reason, st) do
    close_port(st)
    :ok
  end

  # ── internals ────────────────────────────────────────────────────────────────────────────────

  # wake any parked drain waiter with the now-available chunk (or exit).
  defp notify(%{waiters: []} = st), do: st

  defp notify(st) do
    Enum.each(st.waiters, fn {from, timer} ->
      Process.cancel_timer(timer)

      reply =
        if st.sent < byte_size(st.buf), do: take(st), else: {:ok, "", {:exited, st.exit_status}}

      GenServer.reply(from, reply)
    end)

    # all waiters got the SAME pending chunk; advance sent once.
    bump(%{st | waiters: []})
  end

  defp take(st) do
    chunk = binary_part(st.buf, st.sent, byte_size(st.buf) - st.sent)
    status = if st.closed and byte_size(st.buf) - st.sent <= byte_size(chunk), do: {:exited, st.exit_status}, else: :open
    {:ok, chunk, status}
  end

  defp bump(st), do: %{st | sent: byte_size(st.buf)}

  defp close_port(%{port: port} = st) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    %{st | port: nil, closed: true} |> release() |> cleanup()
  end

  defp close_port(st), do: st |> release() |> cleanup()

  # release the broker concurrency slot ONCE (the child's lifetime is over).
  defp release(%{on_release: f} = st) when is_function(f, 0) do
    f.()
    %{st | on_release: nil}
  end

  defp release(st), do: st

  defp cleanup(%{meta: meta} = st) when not is_nil(meta) do
    PackageManager.cleanup_streaming(meta)
    %{st | meta: nil}
  end

  defp cleanup(st), do: st
end
