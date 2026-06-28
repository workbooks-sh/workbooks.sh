defmodule Nexus.WashyHeapCapTest do
  @moduledoc """
  Locks the guest-run interp TERM-heap ceiling (wb-unyo).

  A run whose interpreter heap exceeds `:max_heap_words` is KILLED and CONTAINED as
  `{:error, {:run_killed, _}}` — the caller and the VM survive. The cap rides an UNLINKED monitored
  process, because a `:max_heap_size` kill on a plain (linked) `Task.async` propagates the `:killed`
  exit through the link and takes the CALLER down with it (verified separately). A normal run is
  unaffected, and the off-heap `:atomics` linear memory is NOT counted by the flag, so realistic runs
  never false-kill (a heavy real run's interp heap measured ~1.5 MB).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()),
      do: :ok,
      else: {:skip, "porffor absent"}
  end

  # Print handlers that RETAIN every emitted token on the run-process heap — this is the heap-growth
  # mechanism the cap is meant to bound (a normal discarding handler would let the interp GC it away).
  defp retaining_imports do
    %{
      "a" => fn [v] -> Process.put(:acc, [to_string(v) | Process.get(:acc, [])]); nil end,
      "b" => fn [v] -> Process.put(:acc, [<<trunc(v)::utf8>> | Process.get(:acc, [])]); nil end,
      "c" => fn [] -> 0.0 end,
      "d" => fn [] -> 0.0 end
    }
  end

  defp compile!(src) do
    {:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(src)
    {:ok, mod} = Nexus.Washy.decode(wasm)
    mod
  end

  test "a normal run is unaffected by the default heap ceiling" do
    Process.put(:washy_imports, retaining_imports())
    mod = compile!("console.log(42);")
    assert {:ok, _result, _out, %{}} = Sandbox.run(mod, "m", [], transpile: true)
    assert Process.alive?(self())
  end

  test "a runaway interp heap is killed + contained; the caller survives" do
    Process.put(:washy_imports, retaining_imports())
    # 300k retained prints far exceed a 200k-word (~1.6 MB) ceiling -> killed at a GC mid-run
    mod = compile!("for(var i=0;i<300000;i++){console.log(i);}")

    assert {:error, {:run_killed, _reason}} =
             Sandbox.run(mod, "m", [], transpile: true, max_heap_words: 200_000, timeout_ms: 60_000)

    assert Process.alive?(self())
  end
end
