defmodule Workbooks.IsolationNodeTest do
  @moduledoc """
  wb-pkh.5 — the :node isolation tier (separate BEAM VM) + the #+TRUST escalation
  policy. The :node tests start BEAM distribution (a global side effect), so they're
  tagged :node and excluded from the default run; they skip gracefully where
  distribution can't be brought up.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Fabric, CommandRegistry, IsolationNode, Isolation}

  test "effective_tier: third-party escalates to :node, first-party stays at shape default" do
    assert Isolation.effective_tier("command", nil) == :os_process
    assert Isolation.effective_tier("command", "first-party") == :os_process
    assert Isolation.effective_tier("kernel", "first-party") == :instance
    assert Isolation.effective_tier("component", "first-party") == :instance
    # untrusted supply chain → the strongest live tier (a separate BEAM VM)
    assert Isolation.effective_tier("command", "third-party") == :node
    assert Isolation.effective_tier("kernel", "third-party") == :node
  end

  test ":node is now a live, resolvable tier" do
    assert Isolation.status(:node) == :live
    assert Isolation.live?(:node)
    assert {:ok, :node} = Isolation.resolve(:node)
  end

  @tag :node
  @tag :build
  test "tier :node runs a DYNAMIC command on a separate BEAM VM" do
    if IsolationNode.available?() do
      # A dynamic (third-party-shaped) command, built locally, run on a peer node:
      # IsolationNode syncs its content-addressed artifact to the peer, then runs it.
      name = "noderev_#{System.unique_integer([:positive])}"
      rev = ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|
      {:ok, _} = CommandRegistry.build_and_register_inline(name, "js", rev)

      assert {:ok, [{:ok, "cba"}, {:ok, "olleh"}]} =
               Fabric.map(name, ["abc", "hello"], tier: :node, width: 2)
    else
      # Environment can't bring up distribution (e.g. epmd blocked) — skip, don't fail.
      assert true
    end
  end
end
