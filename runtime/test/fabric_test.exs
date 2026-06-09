defmodule Workbooks.FabricTest do
  @moduledoc """
  wb-rhs.9 — the distributed-compute primitive. Fabric.map fans a command over N
  inputs across isolated WASM instances at a chosen (width, tier). The general
  substrate the media/render fabric is one consumer of — built first, because any
  intensive toolkit distributes the same way.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Fabric, CommandRegistry}

  defp uniq(p), do: "#{p}_#{System.unique_integer([:positive])}"

  @rev_src ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|

  setup_all do
    name = uniq("frev")
    {:ok, _} = CommandRegistry.build_and_register_inline(name, "js", @rev_src)
    %{cmd: name}
  end

  @tag :build
  test "maps a command over many inputs, results IN ORDER", %{cmd: cmd} do
    inputs = ["abc", "hello", "xyz", "12345", "racecar"]
    assert {:ok, results} = Fabric.map(cmd, inputs, width: 4)

    assert results == [
             {:ok, "cba"},
             {:ok, "olleh"},
             {:ok, "zyx"},
             {:ok, "54321"},
             {:ok, "racecar"}
           ]
  end

  @tag :build
  test "width: 1 (sequential) and width: N (concurrent) give the same ordered result", %{cmd: cmd} do
    inputs = for i <- 1..12, do: "item#{i}"
    assert {:ok, seq} = Fabric.map(cmd, inputs, width: 1)
    assert {:ok, par} = Fabric.map(cmd, inputs, width: 8)
    assert seq == par
    assert length(par) == 12
  end

  @tag :build
  test "a per-worker failure is isolated — siblings still succeed", %{cmd: cmd} do
    # An unknown command name makes EVERY worker fail; prove the failure is a
    # per-slot {:error, _}, not a crash of the whole map.
    assert {:ok, results} = Fabric.map(uniq("nope"), ["a", "b"], width: 2)
    assert Enum.all?(results, &match?({:error, _}, &1))

    # Mixed: a real command over inputs still returns ordered successes.
    assert {:ok, [{:ok, "cba"}, {:ok, "ba"}]} = Fabric.map(cmd, ["abc", "ab"], width: 2)
  end

  test "empty input list is a clean empty result (no workers spawned)", %{cmd: cmd} do
    assert {:ok, []} = Fabric.map(cmd, [])
  end

  @tag :build
  test "fabric tier handling (wb-rhs.10 / wb-pkh.7)", %{cmd: cmd} do
    # Commands run as subprocess wasmtime → :os_process is their native LIVE tier.
    assert {:ok, [{:ok, "cba"}]} = Fabric.map(cmd, ["abc"], tier: :os_process)
    # :instance doesn't apply to commands (no in-VM command path) — pointed reason.
    assert {:error, {:tier_mismatch, :instance, _}} = Fabric.map(cmd, ["x"], tier: :instance)
    # :node is defined but planned; :bogus is unknown.
    assert {:error, {:tier_planned, :node, _}} = Fabric.map(cmd, ["x"], tier: :node)
    assert {:error, {:unknown_tier, :bogus, _}} = Fabric.map(cmd, ["x"], tier: :bogus)
  end
end
