# throwaway concern modules at TOP LEVEL, exercising the `<concern>_<op>` → Nexus.Washy.Host<Concern>
# convention (must be real top-level module names for Module.concat resolution to find them).
defmodule Nexus.Washy.HostFaketest do
  def call("faketest_add", [a, b]), do: %{"sum" => a + b}
  def call("faketest_echo", [x]), do: x
end

defmodule Nexus.Washy.HostFakeasync do
  # resolves the completion immediately (a real concern would do work / spawn a Task first)
  def call_async("fakeasync_done", [v], id), do: Nexus.Washy.Actor.io_complete(self(), id, v)
end

defmodule Nexus.WashyHostIOTest do
  @moduledoc "The host-import delegation seam: convention routing for the sync + async generic bridge."
  use ExUnit.Case, async: true

  alias Nexus.Washy.HostIO

  test "dispatch_call routes <concern>_<op> to the convention module's call/2" do
    assert HostIO.dispatch_call("faketest_add", [3, 4]) == %{"sum" => 7}
    assert HostIO.dispatch_call("faketest_echo", [42]) == 42
  end

  test "dispatch_call raises when no concern module implements the op" do
    assert_raise RuntimeError, ~r/no host concern module/, fn ->
      HostIO.dispatch_call("nosuchconcern_op", [])
    end
  end

  test "dispatch_async routes to call_async/3 and returns 0" do
    # io_complete just messages self(); here we only assert the routing + return contract
    assert HostIO.dispatch_async("fakeasync_done", ["x"], 1) == 0
    assert_received {:io_complete, 1, true, "x"}
  end
end
