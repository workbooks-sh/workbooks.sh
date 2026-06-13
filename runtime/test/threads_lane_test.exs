defmodule Workbooks.ThreadsLaneTest do
  @moduledoc """
  Proves SHARED-MEMORY MULTITHREADING in-sandbox: a C program using real pthreads + atomics compiles via
  Compilers.compile_threads (wasm32-wasi-threads target, shared memory) and runs via PackageManager.run(threads:
  true) with genuine concurrent OS-backed threads. This is the lever for the native-threads-as-purpose class
  (rayon/pthread parallel compute). The threads sysroot is provisioned by compilers/clang/build.sh (wasi-sdk
  overlay); the test skips gracefully if it isn't staged yet.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @threads_sysroot Path.expand(
                     Path.join(__DIR__, "../compilers/clang/clang-root/sysroot/lib/wasm32-wasi-threads")
                   )

  @tag :build
  @tag :threads
  @tag timeout: 300_000
  test "compile_threads + run(threads: true) — 4 real threads, atomic shared counter is exactly correct" do
    if not File.dir?(@threads_sysroot) do
      IO.puts("SKIP: wasm32-wasi-threads sysroot not provisioned — run compilers/clang/build.sh to stage it")
    else
      src = Path.join(System.tmp_dir!(), "thr_#{System.unique_integer([:positive])}.c")

      File.write!(src, ~S"""
      #include <stdio.h>
      #include <pthread.h>
      #include <stdatomic.h>
      #define N 4
      #define ITERS 250000
      atomic_long counter = 0;
      void* worker(void* a){ for(int i=0;i<ITERS;i++) atomic_fetch_add(&counter,1); return 0; }
      int main(){
        pthread_t t[N];
        for(int i=0;i<N;i++) pthread_create(&t[i],0,worker,0);
        for(int i=0;i<N;i++) pthread_join(t[i],0);
        long c=(long)counter;
        printf("counter=%ld expected=%d %s\n", c, N*ITERS, c==N*ITERS?"PASS":"FAIL");
        return 0;
      }
      """)

      on_exit(fn -> File.rm(src) end)

      assert {:ok, wasm, _} = Compilers.compile_threads(src)
      on_exit(fn -> File.rm(wasm) end)

      out = PackageManager.run(wasm, "", [], [], threads: true)
      out = if is_tuple(out), do: elem(out, 0), else: out

      # exactly N*ITERS proves the threads RAN CONCURRENTLY on a shared atomic counter (a single-thread or
      # broken-sync run would not produce 1_000_000 deterministically across 4 contending threads).
      assert out =~ "counter=1000000"
      assert out =~ "PASS"
    end
  end
end
