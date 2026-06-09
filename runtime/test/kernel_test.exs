defmodule Workbooks.KernelTest do
  @moduledoc """
  wb-rhs.5 — the hot kernel invocation path. A `bytes → bytes` kernel is
  instantiated ONCE and called many times, reusing the instance + a fixed in/out
  arena (no per-call instantiation, no stdio). The fabric loops this per frame.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Kernel

  @reverse File.read!(Path.join(__DIR__, "fixtures/kernel/reverse.wasm"))

  test "instantiate once, call many — instance + arena reused across calls" do
    {:ok, k} = Kernel.open(@reverse)

    # Many calls on the SAME instance (the hot-loop property). Each reuses the
    # fixed in/out arena — no new Store, no stdio.
    assert {:ok, "cba"} = Kernel.call(k, "abc")
    assert {:ok, "olleh"} = Kernel.call(k, "hello")
    assert {:ok, ""} = Kernel.call(k, "")
    assert {:ok, "x"} = Kernel.call(k, "x")

    # A longer input through the same arena (still one persistent instance).
    big = String.duplicate("ab", 1000)
    assert {:ok, rev} = Kernel.call(k, big)
    assert rev == String.reverse(big)

    Kernel.close(k)
  end

  test "the same kernel handle survives a stream of calls (fabric hot loop)" do
    {:ok, k} = Kernel.open(@reverse)

    # 500 frames through one instance — proves no per-call instantiation.
    for i <- 1..500 do
      s = "frame#{i}"
      assert {:ok, rev} = Kernel.call(k, s)
      assert rev == String.reverse(s)
    end

    Kernel.close(k)
  end

  test "binary-safe (not just ASCII) — bytes round-trip reversed" do
    {:ok, k} = Kernel.open(@reverse)
    bytes = <<0, 1, 2, 254, 255, 128, 7>>
    assert {:ok, out} = Kernel.call(k, bytes)
    assert out == <<7, 128, 255, 254, 2, 1, 0>>
    Kernel.close(k)
  end

  test "a custom entry/arena layout is configurable" do
    # Same fixture, explicit defaults — proves the opts are honored.
    {:ok, k} = Kernel.open(@reverse, entry: "process", in_off: 1024, out_off: 65_536)
    assert {:ok, "dcba"} = Kernel.call(k, "abcd")
    Kernel.close(k)
  end

  describe "Fabric.map_kernel — the render-fabric shape (pool of persistent kernels)" do
    alias Workbooks.Fabric

    test "fans frames across a pool of persistent kernels, ordered results" do
      frames = for i <- 1..50, do: "frame#{i}"
      assert {:ok, results} = Fabric.map_kernel(@reverse, frames, width: 8)

      assert length(results) == 50
      # Order preserved across the pool; each frame reversed by its kernel.
      assert Enum.map(results, fn {:ok, o} -> o end) == Enum.map(frames, &String.reverse/1)
    end

    test "width 1 (one kernel) and width N (pool) agree, in order" do
      frames = for i <- 1..20, do: <<i, i + 1, i + 2>>
      assert {:ok, one} = Fabric.map_kernel(@reverse, frames, width: 1)
      assert {:ok, many} = Fabric.map_kernel(@reverse, frames, width: 6)
      assert one == many
      assert Enum.map(one, fn {:ok, o} -> o end) == Enum.map(frames, fn <<a, b, c>> -> <<c, b, a>> end)
    end

    test "empty frame list is a clean empty result" do
      assert {:ok, []} = Fabric.map_kernel(@reverse, [])
    end

    test "a non-applicable isolation tier is refused with WHY (wb-rhs.10 / wb-1mh)" do
      # kernels run in-VM :instance or on a peer :node; :container isn't built for
      # the persistent kernel path → a pointed reason, not a silent mis-run.
      assert {:error, {:tier_unsupported_for_kernel, :container, _}} =
               Fabric.map_kernel(@reverse, ["x"], tier: :container)
    end
  end

  describe "source→kernel recipe (wb-pkh.1) — author a kernel from C, not a hand-minted fixture" do
    @kernel_c Path.join(__DIR__, "fixtures/kernel/reverse.c")

    @tag :build
    test "C source compiles to a reactor kernel and runs through Kernel(:exports)" do
      # Closes the gap: previously only a hand-authored .wat fixture worked. Now an
      # author writes C and the compiler fabric emits a bytes→bytes kernel.
      {:ok, wasm, _logs} = Workbooks.Compilers.c_compile_to_kernel(@kernel_c)
      {:ok, k} = Kernel.open(File.read!(wasm), arena: :exports)

      assert {:ok, "cba"} = Kernel.call(k, "abc")
      assert {:ok, "321racecar"} = Kernel.call(k, "racecar123")
      # Instance + queried arena reused across many calls (the hot loop).
      for i <- 1..100 do
        s = "f#{i}"
        assert {:ok, rev} = Kernel.call(k, s)
        assert rev == String.reverse(s)
      end

      Kernel.close(k)
      File.rm(wasm)
    end

    @tag :build
    test "a compiled kernel drives the render fabric (Fabric.map_kernel)" do
      {:ok, wasm, _logs} = Workbooks.Compilers.c_compile_to_kernel(@kernel_c)
      bytes = File.read!(wasm)
      frames = for i <- 1..30, do: "frame#{i}"

      assert {:ok, results} = Workbooks.Fabric.map_kernel(bytes, frames, width: 6, arena: :exports)
      assert Enum.map(results, fn {:ok, o} -> o end) == Enum.map(frames, &String.reverse/1)

      File.rm(wasm)
    end
  end
end
