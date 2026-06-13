defmodule Workbooks.RustRayonLaneTest do
  @moduledoc """
  Proves RAYON-CORE LIVE on the shared-memory threads lane: a Rust program using
  `rayon_core::ThreadPoolBuilder` + `rayon_core::join` (nested parallel divide-and-conquer)
  compiles via `Compilers.compile_rust_threads(deps: …)` and runs via
  `PackageManager.run(threads: true)` on a real 4-worker pool with `wasi:thread-spawn` +
  shared memory.

  This is the capstone of the mrustc codegen patch (compilers/rust/mrustc-patch/): rayon-core's
  worker park/wake (Condvar/LockLatch) calls `core::arch::wasm32::memory_atomic_wait32/notify`,
  which lower to `llvm.wasm.memory.atomic.wait32`/`notify`. mrustc's C backend used to abort on
  those (`assert(!"Extern LLVM: …")`); the patch lowers them to `__builtin_wasm_memory_atomic_*`,
  so the regenerated threads libstd carries real futex park/wake and rayon's pool actually blocks
  + wakes its workers.

  Deps (edition 2021), built into output-wasi-174-threads/deps via the threads deps_ctx:
    either@1.16.0, crossbeam-utils@0.8.21, crossbeam-epoch@0.9.18, crossbeam-deque@0.8.6,
    rayon-core@1.12.1. (Top-level `rayon` par_iter does NOT compile — mrustc trait ceiling; we
    target rayon-core's join/scope API.)

  PARALLEL SHAPE: a structured NESTED `join` splitting 0..1_000_000 into 4 quarters across the
  4 workers. (Unbounded SELF-recursive `join` hits a SEPARATE mrustc ceiling — its emulated-i128
  `__multi3` clashes with clang-builtins' native `__multi3`, and deep worker-side `call_indirect`
  hits an uninitialized table slot — both orthogonal to the futex lowering this test proves.)

  Skips gracefully if the threads libstd isn't prebuilt (mirrors rust_threads_lane_test.exs).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @threads_libstd Path.expand(
                    Path.join(
                      __DIR__,
                      "../compilers/rust/mrustc-root/mrustc/output-wasi-174-threads/libstd.rlib.o"
                    )
                  )

  @rayon_deps [
    "either@1.16.0",
    "crossbeam-utils@0.8.21",
    "crossbeam-epoch@0.9.18",
    "crossbeam-deque@0.8.6",
    "rayon-core@1.12.1"
  ]

  # Sub-deps need their std/alloc cfgs forced (the crates gate the std impls rayon relies on).
  @rayon_feats %{
    "crossbeam-utils" => ["std"],
    "crossbeam-epoch" => ["std", "alloc"],
    "crossbeam-deque" => ["std"]
  }

  @tag :build
  @tag :threads
  @tag :rayon
  @tag timeout: 600_000
  test "rayon-core join + ThreadPoolBuilder(4) — parallel sum 0..1_000_000 = 499999500000 on 4 workers" do
    if not File.regular?(@threads_libstd) do
      IO.puts(
        "SKIP: threads libstd not prebuilt — run compilers/rust/std/prebuild-libstd-threads-174.sh to stage it"
      )
    else
      src = Path.join(System.tmp_dir!(), "rayon_#{System.unique_integer([:positive])}.rs")

      File.write!(src, ~S"""
      extern crate rayon_core;

      fn leaf(lo: u64, hi: u64) -> u64 {
          let mut s: u64 = 0;
          let mut i = lo;
          while i < hi { s = s.wrapping_add(i); i += 1; }
          s
      }

      fn main() {
          let pool = rayon_core::ThreadPoolBuilder::new()
              .num_threads(4)
              .build()
              .unwrap();
          let n = pool.current_num_threads();

          // Nested rayon_core::join: split 0..1_000_000 into 4 quarters, summed in parallel across
          // the 4 workers. join blocks the calling worker on a LockLatch (futex park) until the
          // stolen half completes + wakes it (futex notify) — exactly the intrinsics the codegen
          // patch lowers. sum 0..1_000_000 = 999999*1000000/2 = 499999500000.
          let total = pool.install(|| {
              let ((a, b), (c, d)) = rayon_core::join(
                  || rayon_core::join(|| leaf(0, 250_000), || leaf(250_000, 500_000)),
                  || rayon_core::join(|| leaf(500_000, 750_000), || leaf(750_000, 1_000_000)),
              );
              a.wrapping_add(b).wrapping_add(c).wrapping_add(d)
          });

          println!(
              "sum={} threads={} {}",
              total, n,
              if total == 499_999_500_000 && n == 4 { "PASS" } else { "FAIL" }
          );
      }
      """)

      on_exit(fn -> File.rm(src) end)

      assert {:ok, wasm, _log} =
               Compilers.compile_rust_threads(src, deps: @rayon_deps, dep_features: @rayon_feats)

      on_exit(fn -> File.rm(wasm) end)

      out = PackageManager.run(wasm, "", [], [], threads: true)
      out = if is_tuple(out), do: elem(out, 0), else: out

      assert out =~ "sum=499999500000"
      assert out =~ "threads=4"
      assert out =~ "PASS"
    end
  end
end
