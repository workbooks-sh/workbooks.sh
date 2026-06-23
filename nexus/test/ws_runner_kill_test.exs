defmodule Nexus.WsRunnerKillTest do
  @moduledoc "Seam 2.1 / wb-e0dp: re-subscribe kills the prior runner (no orphaned spawns)."
  use ExUnit.Case, async: true

  setup do
    Nexus.Live.register("slow_test_src", fn _p, _emit -> Process.sleep(60_000) end)
    :ok
  end

  test "a second subscribe kills the first runner" do
    state = %{tenant: "t", user: "u", role: "member", runner: nil}
    sub = Jason.encode!(%{"op" => "subscribe", "source" => "slow_test_src"})

    {:ok, s1} = Nexus.Ws.handle_in({sub, [opcode: :text]}, state)
    r1 = s1.runner
    assert is_pid(r1) and Process.alive?(r1)

    {:ok, s2} = Nexus.Ws.handle_in({sub, [opcode: :text]}, s1)
    Process.sleep(50)
    refute Process.alive?(r1), "first runner must be killed on re-subscribe"
    assert is_pid(s2.runner) and Process.alive?(s2.runner)

    Nexus.Ws.terminate(:normal, s2)
  end
end
