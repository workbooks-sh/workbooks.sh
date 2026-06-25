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

  # The concurrency fixtures (pthreads/rayon/tokio) share process-global futex/thread registries; a stale
  # entry or a still-parked worker from one test must not bleed into the next. Clear them between tests so
  # the suite is deterministic (each fixture is independently green; only cross-test state caused flakes).
  setup do
    for tab <- [:washy_futex, :washy_threads] do
      try do
        if :ets.whereis(tab) != :undefined, do: :ets.delete_all_objects(tab)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    for pid <- Process.get(:washy_thread_pids, []), is_pid(pid), do: Process.exit(pid, :kill)
    Process.delete(:washy_thread_pids)
    :ok
  end

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

  # ── wb-t5n9: a REAL concurrency CRATE — rayon — runs interp ≡ asm. `(1..=1000).into_par_iter().sum()`
  # == 500500 → exit(42). Beyond rust_threads it drives the rayon pool: thread_parallelism (pool sizing),
  # thread_spawn_v2/thread_id/thread_join/thread_sleep, and the asyncify stack_checkpoint setjmp hook.
  # Interp is the oracle; the warmed JIT lane must agree.
  @rust_rayon_fixture Path.join(__DIR__, "conformance/wasix/rust_rayon.wasm")

  @tag timeout: 180_000
  test "a real Rust rayon crate (wasix toolchain) runs interp ≡ asm, exits 42 (wb-t5n9)" do
    {:ok, mod} = Washy.decode(File.read!(@rust_rayon_fixture))
    mod = %{mod | id: :wb_t5n9_rayon_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "thread_parallelism" in names, "expected rayon's thread_parallelism import"
    assert Enum.any?(names, &String.starts_with?(&1, "thread")), "expected the WASIX thread surface"
    assert match?({_min, _max, :shared}, mod.mem), "expected an IMPORTED shared memory (threaded crate)"
    assert mod.table_type != nil, "expected an IMPORTED function table"
    assert mod.start != nil, "expected a start function (__wasm_init_memory loads passive data)"

    interp = run(mod, false)

    # warm the tiered JIT so the final asm run executes every hot guest function as native BEAM.
    for _ <- 1..2, do: run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged from the oracle"
    assert interp == {:exit, 42}, "rayon parallel-sum must be 500500 → exit 42, got #{inspect(interp)}"
  end

  # ── §8 tokio (the marquee async runtime): a current-thread tokio runtime drives 1000 `yield_now().await`
  # tasks + a `time::sleep` timer, summing to 500500 → exit 42. Proves the async scheduler + timer run a
  # real async runtime. Ran with NO new host imports — the §2 thread + §0-B poll/clock surface covers it.
  @tokio_fixture Path.join(__DIR__, "conformance/wasix/rust_tokio.wasm")

  @tag timeout: 180_000
  test "the tokio async runtime (current-thread rt + timer) runs interp ≡ asm, exits 42 (wb-t5n9)" do
    {:ok, mod} = Washy.decode(File.read!(@tokio_fixture))
    mod = %{mod | id: :wb_t5n9_tokio_fixture}
    assert match?({_min, _max, :shared}, mod.mem) and mod.start != nil

    interp = run(mod, false)
    for _ <- 1..2, do: run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "tokio runtime must drive the async sum → exit 42, got #{inspect(interp)}"
  end

  # ── §8 serde_json + regex: the biggest binary (5714 fns) — parses JSON, runs a regex with captures,
  # arithmetic on the results → exit 42. Heavy parsing / regex-automata / allocation paths are exactly
  # what stress the asm lane (this class of code surfaced the wb-95w7 store-pops-two bug); proving it
  # interp≡asm hardens the deliverable against real-world parsing crates.
  @parse_fixture Path.join(__DIR__, "conformance/wasix/rust_parse.wasm")

  @tag timeout: 240_000
  test "serde_json + regex (heavy parse/alloc, 5714 fns) runs interp ≡ asm, exits 42 (wb-t5n9)" do
    {:ok, mod} = Washy.decode(File.read!(@parse_fixture))
    mod = %{mod | id: :wb_t5n9_parse_fixture}

    interp = run(mod, false)
    for _ <- 1..3, do: run(mod, true)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)} — asm lane diverged on heavy parse"
    assert interp == {:exit, 42}, "serde_json+regex must compute → exit 42, got #{inspect(interp)}"
  end

  # ── §4/§8 termios: the TUI RUNTIME path with real compiled C. tcgetattr/tcsetattr (raw-mode toggle) +
  # ioctl(TIOCGWINSZ) route through the §4 tty_get/tty_set host imports; returns 42 iff the virtual terminal
  # reports a window size. Proves crossterm/ratatui's RUNTIME need (terminal emulation) works with real
  # compiled code — those Rust crates are blocked only on the compile-side target_family=unix, not the
  # runtime. Run under an attached virtual terminal (Tty.attach), as a TUI program would be.
  @termios_fixture Path.join(__DIR__, "conformance/wasix/unix_termios.wasm")

  test "a termios C program (raw mode + TIOCGWINSZ) drives the §4 tty, interp ≡ asm, exits 42" do
    {:ok, mod} = Washy.decode(File.read!(@termios_fixture))
    mod = %{mod | id: :wb_termios_fixture}

    names = MapSet.new(mod.imports, fn {_m, name, _t} -> name end)
    assert "tty_get" in names and "tty_set" in names, "expected the §4 tty surface"

    Nexus.Washy.Tty.attach(cols: 120, rows: 40)
    interp = run(mod, false)
    asm = run(mod, true)

    assert interp == asm, "interp=#{inspect(interp)} asm=#{inspect(asm)}"
    assert interp == {:exit, 42}, "termios raw-mode + winsize must work → exit 42, got #{inspect(interp)}"
  end
end
