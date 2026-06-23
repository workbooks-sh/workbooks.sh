defmodule Nexus.WsHeartbeatTest do
  @moduledoc """
  Regression: long agent runs over /ws were aborted because the edge proxy (Fly) idle-closes a socket
  after ~60s with no frames — a long turn emits nothing, the proxy drops it, the client stream ends with
  no `done`, and terminate/2 kills the runner. A heartbeat pings the client while the runner works.
  """
  use ExUnit.Case, async: true

  test "heartbeat pings while the runner is alive" do
    runner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:push, {:ping, ""}, %{runner: ^runner}} = Nexus.Ws.handle_info(:ws_heartbeat, %{runner: runner})
    Process.exit(runner, :kill)
  end

  test "heartbeat stops once the runner has exited (done already sent)" do
    runner = spawn(fn -> :ok end)
    Process.sleep(10)
    refute Process.alive?(runner)
    assert {:ok, %{runner: ^runner}} = Nexus.Ws.handle_info(:ws_heartbeat, %{runner: runner})
    refute_received :ws_heartbeat
  end

  test "heartbeat is a no-op with no runner" do
    assert {:ok, %{runner: nil}} = Nexus.Ws.handle_info(:ws_heartbeat, %{runner: nil})
  end
end
