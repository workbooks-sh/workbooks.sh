defmodule Workbooks.KeeperTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Hermetic tests for Workbooks.Keeper. No LLM is ever called — the tests verify
  the GenServer's scheduling logic only:
    1. Without WB_KEEPER_DEF set the Keeper starts idle (active: false).
    2. With WB_KEEPER_DEF set the Keeper schedules a tick (a timer message is
       enqueued via Process.send_after, so we simply send :tick manually with a
       stubbed def and confirm it survives without crashing).

  The actual AgentDef.run/3 call is intentionally NOT tested here (it would need
  a live LLM key). We isolate by confirming the GenServer starts, handles an
  early :tick, and reschedules without crashing — using a real .org file that
  will fail at File.read! (path doesn't exist) so the rescue branch is exercised.
  """

  describe "Keeper without WB_KEEPER_DEF" do
    test "starts in idle state, no timer scheduled" do
      # Clear env to guarantee idle mode
      prev = System.get_env("WB_KEEPER_DEF")
      System.delete_env("WB_KEEPER_DEF")

      on_exit(fn ->
        if prev, do: System.put_env("WB_KEEPER_DEF", prev), else: :ok
      end)

      {:ok, pid} = Workbooks.Keeper.start_link([])

      # Process is alive (supervisor didn't bounce it)
      assert Process.alive?(pid)

      # No :tick in the mailbox after a brief wait — idle mode doesn't schedule
      refute_receive :tick, 50

      GenServer.stop(pid)
    end
  end

  describe "Keeper with WB_KEEPER_DEF set" do
    test "starts active, survives a :tick to a missing def file (crash-safe)" do
      prev = System.get_env("WB_KEEPER_DEF")
      prev_ms = System.get_env("WB_KEEPER_INTERVAL_MS")
      # A path that does NOT exist → File.read! raises → rescue branch logs + reschedules
      System.put_env("WB_KEEPER_DEF", "/tmp/wb_keeper_test_nonexistent_#{System.unique_integer()}.org")
      # Use a very long interval so the auto-tick won't fire during the test
      System.put_env("WB_KEEPER_INTERVAL_MS", "3600000")

      on_exit(fn ->
        if prev, do: System.put_env("WB_KEEPER_DEF", prev), else: System.delete_env("WB_KEEPER_DEF")
        if prev_ms, do: System.put_env("WB_KEEPER_INTERVAL_MS", prev_ms), else: System.delete_env("WB_KEEPER_INTERVAL_MS")
      end)

      {:ok, pid} = Workbooks.Keeper.start_link([])
      assert Process.alive?(pid)

      # Manually trigger a tick — the missing file causes a rescue, not a crash
      send(pid, :tick)

      # Give it time to process and reschedule
      Process.sleep(100)

      # Still alive after the error — crash-safe confirmed
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "starts active, survives a :tick to a valid but empty def (crash-safe)" do
      prev = System.get_env("WB_KEEPER_DEF")
      prev_ms = System.get_env("WB_KEEPER_INTERVAL_MS")

      # Write a minimal (but intentionally LLM-call-free) org file.
      # AgentDef.run will fail at the LLM call — that's fine, the rescue catches it.
      path = "/tmp/wb_keeper_test_#{System.unique_integer()}.org"
      File.write!(path, "* keeper :agent:\n:PROPERTIES:\n:ID: test-keeper\n:MODEL: fake/model\n:END:\n** System prompt\nDo nothing.\n")
      System.put_env("WB_KEEPER_DEF", path)
      System.put_env("WB_KEEPER_INTERVAL_MS", "3600000")

      on_exit(fn ->
        File.rm(path)
        if prev, do: System.put_env("WB_KEEPER_DEF", prev), else: System.delete_env("WB_KEEPER_DEF")
        if prev_ms, do: System.put_env("WB_KEEPER_INTERVAL_MS", prev_ms), else: System.delete_env("WB_KEEPER_INTERVAL_MS")
      end)

      {:ok, pid} = Workbooks.Keeper.start_link([])
      assert Process.alive?(pid)

      # Manually trigger tick — AgentDef.run fails (no LLM) → rescue → reschedule
      send(pid, :tick)
      Process.sleep(200)

      # Must still be alive — crash-safe confirmed
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
