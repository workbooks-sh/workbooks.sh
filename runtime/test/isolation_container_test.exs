defmodule Workbooks.IsolationContainerTest do
  @moduledoc """
  wb-kt6 — the :container isolation tier. A command's wasm runs in a throwaway
  container (--network none + mem/cpu/pids caps + read-only rootfs). The :container
  e2e is tagged and skips where docker + the wasmtime image aren't available.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{CommandRegistry, IsolationContainer, Fabric, Isolation}

  @rev ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|

  test ":container is a live, resolvable tier" do
    assert Isolation.status(:container) == :live
    assert Isolation.live?(:container)
    assert {:ok, :container} = Isolation.resolve(:container)
  end

  test "an unknown command can't run in a container → clear error, not a crash" do
    name = "ghost_#{System.unique_integer([:positive])}"
    assert {:error, {:container_unsupported_command, ^name}} = IsolationContainer.run(name, "x")
  end

  @tag :container
  @tag :build
  test "tier :container runs a command in a throwaway container" do
    if IsolationContainer.available?() do
      name = "crev_#{System.unique_integer([:positive])}"
      {:ok, _} = CommandRegistry.build_and_register_inline(name, "js", @rev)

      assert {:ok, "cba"} = IsolationContainer.run(name, "abc")

      assert {:ok, [{:ok, "cba"}, {:ok, "olleh"}]} =
               Fabric.map(name, ["abc", "hello"], tier: :container, width: 2)
    else
      assert true
    end
  end
end
