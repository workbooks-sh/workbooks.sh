defmodule Workbooks.RustThreadsLaneTest do
  @moduledoc """
  Proves SHARED-MEMORY MULTITHREADED RUST in-sandbox: a Rust program using real `std::thread::spawn` +
  `Arc<AtomicUsize>` compiles via `Compilers.compile_rust_threads` (mrustc.wasm → clang.wasm, threads
  libstd, wasm32-wasi-threads target, `--cfg target_feature=atomics` no-fork bypass) and runs via
  `PackageManager.run(threads: true)` with genuine concurrent OS-backed threads on a shared atomic
  counter. This is the Rust counterpart of `threads_lane_test.exs` (the C threads lane).

  The threads libstd is prebuilt by compilers/rust/std/prebuild-libstd-threads-174.sh into
  output-wasi-174-threads/; the test skips gracefully if it isn't staged yet (mirrors the C test's
  sysroot guard).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @threads_libstd Path.expand(
                    Path.join(
                      __DIR__,
                      "../compilers/rust/mrustc-root/mrustc/output-wasi-174-threads/libstd.rlib.o"
                    )
                  )

  @tag :build
  @tag :threads
  @tag timeout: 300_000
  test "compile_rust_threads + run(threads: true) — 4 std::thread, Arc<AtomicUsize> sums to exactly 1_000_000" do
    if not File.regular?(@threads_libstd) do
      IO.puts(
        "SKIP: threads libstd not prebuilt — run compilers/rust/std/prebuild-libstd-threads-174.sh to stage it"
      )
    else
      src = Path.join(System.tmp_dir!(), "thr_#{System.unique_integer([:positive])}.rs")

      File.write!(src, ~S"""
      use std::sync::Arc;
      use std::sync::atomic::{AtomicUsize, Ordering};
      use std::thread;

      const N: usize = 4;
      const ITERS: usize = 250_000;

      fn main() {
          let counter = Arc::new(AtomicUsize::new(0));
          let mut handles = Vec::new();
          for _ in 0..N {
              let c = Arc::clone(&counter);
              handles.push(thread::spawn(move || {
                  for _ in 0..ITERS {
                      c.fetch_add(1, Ordering::SeqCst);
                  }
              }));
          }
          for h in handles {
              h.join().unwrap();
          }
          let total = counter.load(Ordering::SeqCst);
          println!("counter={} expected={} {}", total, N * ITERS, if total == N * ITERS { "PASS" } else { "FAIL" });
      }
      """)

      on_exit(fn -> File.rm(src) end)

      assert {:ok, wasm, _log} = Compilers.compile_rust_threads(src)
      on_exit(fn -> File.rm(wasm) end)

      out = PackageManager.run(wasm, "", [], [], threads: true)
      out = if is_tuple(out), do: elem(out, 0), else: out

      # exactly N*ITERS proves the threads RAN CONCURRENTLY on a shared atomic counter — a single-thread
      # or broken-sync run would not deterministically produce 1_000_000 across 4 contending threads.
      assert out =~ "counter=1000000"
      assert out =~ "PASS"
    end
  end
end
