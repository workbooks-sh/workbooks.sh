defmodule Nexus.Porffor.AsyncFiber do
  @moduledoc """
  **Cooperative single-active-fiber scheduler for JS async/await on the BEAM (G3 — real suspension).**

  Porffor compiles `async` functions to in-wasm code that runs to completion synchronously (`await` is a peek
  hack), so cross-async microtask ordering can't match node. The fix uses the BEAM as the coroutine substrate
  (the same wasm-threads infra Washy already has — shared `:atomics` memory + futex `atomic.wait`/`notify`):

    * Each async invocation runs its body on its OWN BEAM process — a **fiber** — sharing the guest's wasm
      memory. A fiber's blocked call stack *is* the suspended async continuation (no state-machine / CPS
      transform needed — BEAM gives stackful coroutines for free).
    * The wasm microtask `jobQueue` + `__Porffor_promise_runJobs` stay the AUTHORITATIVE scheduler (so ordering
      is exactly node's). Fibers only provide suspension. `await p` (pending) appends a normal "resume-fiber"
      reaction to `p` — which settles in the correct microtask order via the existing promise machinery — then
      parks the fiber. The resume reaction wakes the fiber.
    * **Only one fiber/scheduler runs at any instant** (cooperative handoff via messages): a spawner/resumer
      blocks until the fiber parks again or completes. This serializes all execution over the shared memory →
      coherence + isolation preserved; fuel still bounds each run. No real parallelism leaks into the guest.

  This module is the integration-independent CORE: the **handoff protocol** between a controller (spawner or
  resumer) and a fiber, proven over BEAM processes with simulated fiber bodies. The wasm wiring (a fiber body
  = a Washy instance invocation; `park`/`resume` = host imports; `await` appends the resume reaction) layers on
  top, reusing `guest_atomic_wait`/`guest_atomic_notify` for the actual park/wake. See the test for the proof.

  ## Protocol

  A fiber body is a function that runs and, at each suspension point, calls `park/1` (yields control to the
  controller, returns when resumed) and finally returns its result. The controller drives via:

    * `spawn_fiber(body)` → starts the fiber, blocks until it first parks or completes, returns
      `{:parked, fiber}` or `{:done, result}`.
    * `resume(fiber, value)` → wakes a parked fiber with `value`, blocks until it parks again or completes,
      returns `{:parked, fiber}` or `{:done, result}`.

  `park/1` is called from INSIDE the fiber body; it hands control back to the controller and blocks until the
  next `resume`, returning the resumed value. Exactly one of {controller, fiber} is runnable at any time.
  """

  @type fiber :: %{pid: pid, ref: reference}

  # ── controller side ─────────────────────────────────────────────────────────────────────────────────

  @doc """
  Start `body` on a fresh fiber process and block until it first parks or completes.
  Returns `{:parked, fiber}` (suspended at its first `park/1`) or `{:done, result}` (ran straight through).
  """
  @spec spawn_fiber((-> any)) :: {:parked, fiber} | {:done, any} | {:error, any}
  def spawn_fiber(body) when is_function(body, 0) do
    controller = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        Process.put(:wb_fiber_controller, controller)
        Process.put(:wb_fiber_ref, ref)

        result =
          try do
            {:ok, body.()}
          catch
            kind, reason -> {:thrown, kind, reason}
          end

        send(controller, {:wb_fiber_done, ref, result})
      end)

    await_yield(%{pid: pid, ref: ref})
  end

  @doc """
  Wake a parked fiber, handing it `value` (the resolved await value), and block until it parks again or
  completes. Returns `{:parked, fiber}` or `{:done, result}`.
  """
  @spec resume(fiber, any) :: {:parked, fiber} | {:done, any} | {:error, any}
  def resume(%{pid: pid, ref: ref} = fiber, value) do
    send(pid, {:wb_fiber_resume, ref, value})
    await_yield(fiber)
  end

  # Block until the active fiber yields control: either it parked (suspended) or finished.
  defp await_yield(%{ref: ref} = fiber) do
    receive do
      {:wb_fiber_parked, ^ref} -> {:parked, fiber}
      {:wb_fiber_done, ^ref, {:ok, result}} -> {:done, result}
      {:wb_fiber_done, ^ref, {:thrown, kind, reason}} -> {:error, {kind, reason}}
    end
  end

  # ── fiber side ──────────────────────────────────────────────────────────────────────────────────────

  @doc """
  Called from inside a fiber body at a suspension point (an `await` on a pending promise). Hands control back
  to the controller (sends `:wb_fiber_parked`) and blocks until the next `resume`, returning the resumed value.
  The fiber's BEAM call stack is preserved across this block — that IS the suspended async continuation.
  """
  @spec park(any) :: any
  def park(park_info \\ nil) do
    controller = Process.get(:wb_fiber_controller) || raise "park/1 called outside a fiber"
    ref = Process.get(:wb_fiber_ref)
    _ = park_info
    send(controller, {:wb_fiber_parked, ref})

    receive do
      {:wb_fiber_resume, ^ref, value} -> value
    end
  end

  @doc "True when the current process is a fiber (so async codegen can choose spawn-mode vs run-mode)."
  @spec in_fiber?() :: boolean
  def in_fiber?, do: Process.get(:wb_fiber_controller) != nil
end
