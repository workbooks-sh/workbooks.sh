defmodule Nexus.Porffor.GeneratorHost do
  @moduledoc """
  **Host import handlers that wire a Porffor-compiled JS generator onto a Washy suspension fiber.**

  This is the wasm-invoking layer between the guest and `Nexus.Porffor.GeneratorFiber` (the handle/cap/
  kill-set driver) over `Nexus.Porffor.AsyncFiber` (the baton/park handoff). The guest calls three host
  imports — declared in `compiler/wrap.js`, registered into `:washy_imports` via `imports/0`:

    * `__porffor_gen_spawn(funcref) -> handle`  — `g()`: spawn the body on a fiber, run to its first
      `yield`, return an integer handle. (The first yielded value is buffered and delivered by the first
      resume — JS runs nothing until `it.next()`, so the eager run-to-first-yield is held, not delivered.)
    * `__porffor_gen_yield(mbxPtr) -> 0`        — `yield e` inside the body (runs ON THE FIBER): hand the
      yielded value out and block until resumed, then deliver the sent value back. Reads/writes the value
      at `mbxPtr`.
    * `__porffor_gen_resume(handle, mbxPtr) -> done` — `it.next(v)`: resume the fiber with the value at
      `mbxPtr`, write the next yielded (or return) value back to `mbxPtr`, return `0` (yielded) / `1`
      (done) / `2` (unknown/dead handle → value left `undefined`).

  ## The `any`-value mailbox ABI

  A JS value crossing the boundary is an `any` = a 12-byte blob: an f64 value (8 bytes) + an i32 runtime
  type tag (4 bytes), the shape Porffor passes any-typed args/returns in. The host treats the blob
  **opaquely** — it never dereferences it, so an object/array value (whose blob is a guest pointer) shuttles
  through untouched. Transfer rides a guest **mailbox** scratch region (the guest writes the value there,
  passes the pointer); a single shared mailbox is race-free because exactly one of {controller, fiber} runs
  at any instant (`AsyncFiber`'s single-active baton). All three imports take/return plain i32, so the ABI
  is identical across the interp / cps / transpile lanes (no multi-value-return path to keep in sync).

  ## Isolation

  Reuses `GeneratorFiber`'s baked-in requirements (process-local handles, per-run live cap, kill-set
  registration in `:washy_thread_pids`) and `gen_capture_context/0`'s shared per-run fuel (invariant 4).
  Fibers park on the unforgeable `make_ref` message channel — never the guest-writable futex addr — so they
  leave NO `:washy_futex` ETS rows (invariant 7 holds by construction; nothing to purge).
  """

  alias Nexus.Porffor.{AsyncFiber, GeneratorFiber}

  # Mailbox layout (a guest scratch region): an `any` value blob — f64 value (8 bytes, little-endian) ++
  # i32 type tag (4 bytes) @ +0 — then the i32 DONE flag @ +12. The value blob carries `yield`/`next(v)`
  # values both ways; the done flag is written by `gen_resume` so the guest reads it via `i32.load(mbx+12)`.
  # We put done in memory rather than the import's return value because Porffor's return-type inference
  # tags a host import's result `undefined` once the guest is closure-converted — an `i32.load` is reliable.
  @blob_bytes 12
  @done_off 12
  @undefined_blob <<0::size(@blob_bytes)-unit(8)>>

  # The imports are declared f64 (Porffor valtype) in wrap.js, so every handler MUST return a FLOAT — an
  # integer result reaches the guest as an f64 the runtime later float-reinterprets (and crashes on).
  @bad_handle -1.0
  @ok 0.0

  # done-flag values written to the mailbox (read back by the guest as an i32).
  @done_yielded 0
  @done_finished 1
  @done_inert 2

  @doc "The Porffor-lane `:washy_imports` entries for the three generator host imports (idents f/g/h)."
  @spec imports() :: %{optional(String.t()) => (list -> integer)}
  def imports do
    %{
      "f" => &__MODULE__.gen_spawn/1,
      "g" => &__MODULE__.gen_yield/1,
      "h" => &__MODULE__.gen_resume/1
    }
  end

  # ── __porffor_gen_spawn(funcref) -> handle  (runs on the CONTROLLER — the guest invoking g()) ──────────
  @doc false
  def gen_spawn([funcref_f64 | _]) do
    rt = Process.get(:washy_rt) || raise "__porffor_gen_spawn outside a washy run"
    table_idx = trunc(funcref_f64)

    case Map.get(rt.table, table_idx) do
      nil ->
        # an unresolvable funcref — the guest handed us a bad reference; report no generator.
        @bad_handle

      gfidx ->
        ctx = Nexus.Washy.gen_capture_context()
        args = funcref_call_args(rt, gfidx)

        body = fn ->
          Nexus.Washy.gen_adopt_context(ctx)
          # the body's return value isn't delivered here (v3 lowers `return e` through the mailbox); the
          # fiber simply runs the wasm generator body, parking at each yield via __porffor_gen_yield.
          Nexus.Washy.call_local(gfidx, args)
        end

        case GeneratorFiber.spawn(body) do
          {:yield, handle, blob} ->
            put_pending(handle, {:yield, blob})
            handle * 1.0

          {:done, _result} ->
            # a generator with no `yield` at all: hand back a fiber-less handle whose first resume reports
            # done. (v3 lowers `return e` so the return value rides the mailbox; here it's undefined.)
            handle = GeneratorFiber.reserve_handle()
            put_pending(handle, {:done, @undefined_blob})
            handle * 1.0

          {:error, _reason} ->
            @bad_handle
        end
    end
  end

  # ── __porffor_gen_yield(mbxPtr) -> 0  (runs ON THE FIBER, inside the suspended body) ───────────────────
  @doc false
  def gen_yield([mbx_f64 | _]) do
    mem = Process.get(:washy_mem)
    mbx = trunc(mbx_f64)
    yielded = Nexus.Washy.read_bytes(mem, mbx, @blob_bytes)
    # hand the yielded value out to the controller and block until it resumes us with the sent value.
    resumed = AsyncFiber.park(yielded)
    Nexus.Washy.write_bytes(mem, mbx, normalize_blob(resumed))
    @ok
  end

  # ── __porffor_gen_resume(handle, mbxPtr) -> done  (runs on the CONTROLLER — it.next(v)) ────────────────
  @doc false
  def gen_resume([handle_f64, mbx_f64 | _]) do
    mem = Process.get(:washy_mem)
    handle = trunc(handle_f64)
    mbx = trunc(mbx_f64)

    case take_pending(handle) do
      # First it.next(): JS does not pass a value into the start of a generator, so we deliver the buffered
      # first yield WITHOUT resuming the body (it already ran to its first yield at spawn). done = 0.
      {:yield, blob} ->
        write_result(mem, mbx, blob, @done_yielded)

      # A no-yield generator's first .next() (or any call on an already-exhausted handle): {value, done:true}.
      # Re-buffer the exhausted marker so repeated .next() keep reporting {undefined, done:true} per spec.
      {:done, blob} ->
        put_pending(handle, {:done, @undefined_blob})
        write_result(mem, mbx, blob, @done_finished)

      nil ->
        sent = Nexus.Washy.read_bytes(mem, mbx, @blob_bytes)

        case GeneratorFiber.resume(handle, sent) do
          {:yield, blob} ->
            write_result(mem, mbx, normalize_blob(blob), @done_yielded)

          {:done, _result} ->
            # the fiber is finished and its handle freed; keep an exhausted marker so further .next() are inert.
            put_pending(handle, {:done, @undefined_blob})
            write_result(mem, mbx, @undefined_blob, @done_finished)

          {:error, _reason} ->
            write_result(mem, mbx, @undefined_blob, @done_inert)
        end
    end
  end

  # write the value blob + the i32 done flag into the mailbox, return the (ignored) f64 import result.
  defp write_result(mem, mbx, blob, done) do
    Nexus.Washy.write_bytes(mem, mbx, blob)
    Nexus.Washy.write_bytes(mem, mbx + @done_off, <<done::32-little>>)
    @ok
  end

  # The funcref resolved to its `#indirect_<name>` wrapper — the wrapperArgc=16 ABI (argc i32 + 16 arg
  # value/type pairs + this + new.target). For a 0-arg generator we pass type-matched UNDEFINED: 0 for an
  # i32 slot, 0.0 for an f64 slot. `call_local` reverses args into the locals tuple, so build in param order
  # and reverse here. (v3: a generator WITH params marshals the real call args into the arg-pair slots.)
  defp funcref_call_args(rt, gfidx) do
    tyidx = Enum.at(rt.mod.funcs, gfidx - rt.ni)
    {params, _results} = Enum.at(rt.mod.types, tyidx)

    params
    |> Enum.map(fn
      124 -> 0.0
      _ -> 0
    end)
    |> Enum.reverse()
  end

  # ── first-yield buffer (controller process dict; handles are process-local already) ───────────────────
  defp put_pending(handle, state) do
    Process.put(:washy_gen_pending, Map.put(Process.get(:washy_gen_pending, %{}), handle, state))
  end

  defp take_pending(handle) do
    pend = Process.get(:washy_gen_pending, %{})

    case Map.pop(pend, handle) do
      {nil, _} -> nil
      {state, rest} -> Process.put(:washy_gen_pending, rest); state
    end
  end

  # a parked/sent value is the 12-byte blob; nil (a bare park with no value) is undefined.
  defp normalize_blob(blob) when is_binary(blob) and byte_size(blob) == @blob_bytes, do: blob
  defp normalize_blob(_), do: @undefined_blob
end
