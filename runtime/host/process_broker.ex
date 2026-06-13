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

    # reserve a process slot (refuse past the per-principal cap = fork-bomb gate). The WORKER process holds the
    # slot for its whole life and releases it exactly ONCE on exit — and it exits on REAP (await), the parent
    # DYING, or a max-lifetime. So a slot can never leak: abandoned/orphaned processes self-release (a guest
    # can't permanently exhaust its cap by spawning-without-await or dying).
    if reserve(principal, max_proc) do
      ref = make_ref()
      parent = self()
      lifetime = Keyword.get(opts, :max_lifetime, 60_000)
      # released-once flag (0 = slot live, 1 = released). await/kill release SYNCHRONOUSLY in the caller; the
      # worker is the safety net for orphan (parent death) / abandon (lifetime). The atomic flag guarantees
      # the slot decrements EXACTLY once no matter which path wins.
      flag = :atomics.new(1, signed: false)

      pid =
        Kernel.spawn(fn ->
          pmon = Process.monitor(parent)
          result = Workbooks.ExecBroker.exec(name, argv, stdin, opts)
          send(parent, {__MODULE__, ref, :done, result})

          receive do
            {__MODULE__, ^ref, :stop} -> :ok
            {:DOWN, ^pmon, :process, _, _} -> guarded_release(flag, principal)
          after
            lifetime -> guarded_release(flag, principal)
          end
        end)

      {:ok, %{ref: ref, pid: pid, principal: principal, flag: flag}}
    else
      Workbooks.BrokerAudit.record(:process, :deny, :max_processes, principal)
      {:error, :max_processes}
    end
  end

  @doc """
  Wait for (REAP) a spawned process; returns its ExecBroker result ({:ok, output} | {:error, _}) and releases
  the process's slot SYNCHRONOUSLY. A second await on the same handle returns {:error, :timeout}.
  """
  def await(%{ref: ref, pid: pid, principal: principal, flag: flag}, timeout \\ 30_000) do
    receive do
      {__MODULE__, ^ref, :done, result} ->
        guarded_release(flag, principal)
        if Process.alive?(pid), do: send(pid, {__MODULE__, ref, :stop})
        result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc "Reap a spawned process WITHOUT collecting its output, releasing its slot synchronously."
  def kill(%{ref: ref, pid: pid, principal: principal, flag: flag}) do
    guarded_release(flag, principal)
    if Process.alive?(pid), do: send(pid, {__MODULE__, ref, :stop})
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

  # release the slot EXACTLY ONCE — the atomic flag's 0->1 swap is won by only one caller (await/kill/worker)
  defp guarded_release(flag, principal) do
    if :atomics.exchange(flag, 1, 1) == 0, do: release(principal)
  end

  defp release(principal), do: :ets.update_counter(table(), principal, {2, -1}, {principal, 0})

  defp table, do: Workbooks.BrokerTables.ensure(@counts, [:named_table, :public, :set])
end
