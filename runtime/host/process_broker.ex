defmodule Workbooks.ProcessBroker do
  @moduledoc """
  wb-broker FORK-EXEC / MULTI-PROCESS MODEL — the host-brokered substitute for `fork()`+`exec()`/`posix_spawn`,
  which wasip1/p2 lack. A guest that needs to spawn a subprocess gets a brokered SANDBOXED process instead: the
  host starts the requested command in its OWN fresh isolated wasm instance (via ExecBroker — the full exec
  sandbox), hands back a HANDLE, and lets the parent run it ASYNCHRONOUSLY — `spawn` (non-blocking) -> `await`
  (collect output + exit) / `kill` (terminate). This is the lifecycle a real fork-exec'd process has, which
  the synchronous ExecBroker.exec and the batch ParallelBroker.map don't expose.

  Security cadence (all of ExecBroker's — default-deny/registered-only/no-injection/output-cap/depth/revocation
  /rate — applies PER spawned process, since each is a real ExecBroker.exec) PLUS the fork-exec-specific guard:
    * FORK-BOMB DEFENSE — a per-PRINCIPAL cap on CONCURRENT live processes (`@max_processes`). A guest cannot
      spawn unbounded processes (the classic fork-bomb); the (@max_depth) nesting bound + this concurrency cap
      together bound both the depth and the width of a process explosion.
  Backed by a registry (the long-lived BrokerTables-owned ETS) tracking each principal's live process count.
  """
  @counts :wb_proc_counts
  @max_processes 32

  @doc """
  Spawn `name`(argv) with `stdin` as a brokered sandboxed process. Non-blocking: returns `{:ok, handle}` (an
  opaque ref) immediately; the process runs in a fresh wasm instance. opts are ExecBroker's (:allow,
  :commands, :max_output, :depth, :principal, :rate) + `:max_processes`. `{:error, :max_processes}` once the
  principal's concurrent-process cap is hit (fork-bomb defense). Other cadence denials surface from ExecBroker
  at `await`.
  """
  def spawn(name, argv, stdin, opts \\ [])
      when is_binary(name) and is_list(argv) and is_binary(stdin) do
    principal = Keyword.get(opts, :principal, "_anon")
    max_proc = Keyword.get(opts, :max_processes, @max_processes)

    # reserve a process slot (refuse past the per-principal cap = fork-bomb gate). The slot is held until the
    # process is REAPED (await) or killed — fork-exec semantics: a finished-but-unreaped process is a zombie
    # that still occupies a slot until the parent wait()s on it.
    if reserve(principal, max_proc) do
      ref = make_ref()
      parent = self()

      pid =
        Kernel.spawn(fn ->
          result = Workbooks.ExecBroker.exec(name, argv, stdin, opts)
          send(parent, {__MODULE__, ref, :done, result})
        end)

      {:ok, %{ref: ref, pid: pid, principal: principal}}
    else
      Workbooks.BrokerAudit.record(:process, :deny, :max_processes, principal)
      {:error, :max_processes}
    end
  end

  @doc """
  Wait for (REAP) a spawned process; returns its ExecBroker result ({:ok, output} | {:error, _}) and releases
  the process's slot. Awaiting is idempotent-ish — a second await on the same handle returns {:error, :timeout}.
  """
  def await(%{ref: ref, principal: principal}, timeout \\ 30_000) do
    receive do
      {__MODULE__, ^ref, :done, result} ->
        release(principal)
        result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Kill a still-running spawned process and release (reap) its slot."
  def kill(%{pid: pid, principal: principal}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    release(principal)
    :ok
  end

  @doc "Current live-process count for a principal (for tests / introspection)."
  def live_count(principal), do: :ets.update_counter(table(), principal, {2, 0}, {principal, 0})

  # reserve a slot: bump the count, but if it would exceed max, roll back and refuse (the fork-bomb gate)
  defp reserve(principal, max) do
    n = :ets.update_counter(table(), principal, {2, 1}, {principal, 0})

    if n > max do
      :ets.update_counter(table(), principal, {2, -1}, {principal, 0})
      false
    else
      true
    end
  end

  defp release(principal), do: :ets.update_counter(table(), principal, {2, -1}, {principal, 0})

  defp table, do: Workbooks.BrokerTables.ensure(@counts, [:named_table, :public, :set])
end
