defmodule Nexus.WashyWasixCTest do
  @moduledoc """
  **WASIX §7/§8 C-conformance — a REAL unix C program runs on the runtime (epic wb-a531, oracle wb-t5n9).**

  `test/conformance/wasix/unix_socket_poll.wasm` is `unix_socket_poll.c` — `#include <sys/socket.h>` +
  `<poll.h>`, `socket(AF_INET, SOCK_STREAM, 0)` + `poll()` + `return 42` — compiled UNCHANGED against
  wasix-libc (`target_family=unix`). This proves the whole stack end-to-end with no shims:

    * §7 (compile side): unix-targeting C source compiles against wasix-libc → a wasm module whose imports
      are `wasi_snapshot_preview1.{fd_write,poll_oneoff,sched_yield,…}` + `wasix_32v1.{sock_open,futex_wait,
      futex_wake,proc_signals_*,proc_exit2,…}`.
    * §8 (run side): the module RUNS on Washy — its `socket()` lands on our §3 `sock_open`, `poll()` on the
      §0-B `poll_oneoff`, the libc thread/signal startup on the §2 futex + §6 signal host imports — and
      `_start` exits with main()'s 42. And it does so IDENTICALLY in the interpreter and the asm/transpiler
      lane (interp ≡ asm), which is the §8 bar.

  The committed `.wasm` makes this run with no toolchain present (see BUILD.md to regenerate). The Rust-std
  side of §7 (tokio/hyper/ratatui) needs the provisioned compiler-build machine — bd wb-dkwy runbook.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @fixture Path.join(__DIR__, "conformance/wasix/unix_socket_poll.wasm")

  defp run(mod, transpile?) do
    try do
      Washy.call_io(mod, "_start", [], transpile: transpile?, tier_threshold: 1, tier_async: false)
      :no_exit
    catch
      :throw, {:washy_exit, code} -> {:exit, code}
    end
  end

  test "a wasix-libc unix C binary (socket+poll) runs on the runtime, interp ≡ asm, exits 42" do
    {:ok, mod} = Washy.decode(File.read!(@fixture))

    # It really is a unix-targeted module: it imports the WASIX socket + futex host calls our runtime serves.
    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "sock_open" in names, "expected the wasix sock_* surface"
    assert "poll_oneoff" in names
    assert "futex_wait" in names, "expected the WASIX futex host import (wasi-libc threads)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "the unix binary must run and exit with main()'s 42, got #{inspect(interp)}"
  end

  # ── wb-95w7: a wasix-libc fs program (open/write/read + dlmalloc) — interp ≡ asm, including the WARMED
  # asm lane (every guest function compiled to BEAM assembly). This is the §8 oracle that caught the
  # store-pops-one-not-two bug: a single off-by-one in a store's operand-depth corrupted dlmalloc's
  # returned pointer, so the program diverged ONLY after its functions got JIT-compiled (tiered lane).
  @memcmp_fixture Path.join(__DIR__, "conformance/wasix/_memcmp_divergence.wasm")

  test "a wasix-libc fs program runs interp ≡ asm, including the warmed JIT lane (wb-95w7)" do
    {:ok, mod} = Washy.decode(File.read!(@memcmp_fixture))
    # tag the module so the tiered JIT can cache its compiled functions across the warm-up runs.
    mod = %{mod | id: :wb95w7_memcmp_fixture}

    interp = run(mod, false)

    # warm the tiered JIT: each call compiles the functions that crossed the threshold, so by the final
    # run EVERY hot guest function executes as native BEAM assembly (where the store bug used to surface).
    for _ <- 1..3, do: run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged from the oracle"
  end

  # ── §2: a real wasi-libc PTHREADS program — proves the whole concurrency stack with compiled C. Two
  # threads each increment a shared atomic counter 1000×, pthread_join, expect 2000 → return 42. Exercises
  # thread_spawn → wasi_thread_start, the {min,max,:shared} memory model, C11 atomics, and futex_wait/wake
  # (inside pthread_join). Runs identically in the interpreter and the asm lane.
  @pthread_fixture Path.join(__DIR__, "conformance/wasix/unix_pthread.wasm")

  test "a wasix-libc pthreads program (2 threads, shared atomic counter) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Washy.decode(File.read!(@pthread_fixture))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names and ("thread-spawn" in names or "thread_spawn" in names)
    assert match?({_min, _max, :shared}, mod.mem), "expected a shared memory (threaded module)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "2 threads × 1000 atomic incs must total 2000 → 42, got #{inspect(interp)}"
  end

  # ── WASIX §8 Rust-std oracle (wb-t5n9): a REAL Rust std binary compiled with the wasix rustup toolchain
  # — 2 threads × 1000 AtomicI32::fetch_add, join, exit(42). Unlike the C fixtures it IMPORTS its shared
  # memory AND its function table, and ships PASSIVE data segments copied in by the `start` function
  # (__wasm_init_memory) — so it proves the imported-table decode + the section-8 start-function execution
  # (without which rodata vtables stay zero and call_indirect traps :undefined_element). Interp ≡ asm.
  @rust_threads_fixture Path.join(__DIR__, "conformance/wasix/rust_threads.wasm")

  test "a real Rust-std threads binary (wasix toolchain) runs interp ≡ asm, exits 42" do
    {:ok, mod} = Washy.decode(File.read!(@rust_threads_fixture))

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "futex_wait" in names and Enum.any?(names, &String.starts_with?(&1, "thread"))
    assert match?({_min, _max, :shared}, mod.mem), "expected an IMPORTED shared memory (threaded module)"
    assert mod.table_type != nil, "expected an IMPORTED function table"
    assert mod.start != nil, "expected a start function (__wasm_init_memory loads passive data)"

    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "real Rust threads must total 2000 → exit 42, got #{inspect(interp)}"
  end
end
