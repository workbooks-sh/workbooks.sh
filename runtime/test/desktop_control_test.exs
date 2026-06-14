defmodule Workbooks.DesktopControlTest do
  @moduledoc """
  DesktopControl pushes app/tab commands to connected desktop shells. It must be
  tenant-scoped (wb-g1yo): a `wb app theme/tab/…` command drives only the caller's
  own shell, not every desktop on a shared nexus. Mirrors the env/workgate broker
  scoping. The test process stands in for a shell.
  """
  use ExUnit.Case, async: false

  alias Workbooks.DesktopControl

  test "a command reaches the caller's own shell" do
    DesktopControl.register("jr-self", "alice")
    {:ok, n} = DesktopControl.command("set_theme", %{"id" => "dark"}, "alice")
    assert n >= 1

    assert_receive {:channel_push, "jr-self", _topic, "app_command", payload}, 1_000
    assert payload["action"] == "set_theme"
    assert payload["id"] == "dark"
  end

  test "a command is NOT pushed to another tenant's shell (wb-g1yo)" do
    test_pid = self()

    bob =
      spawn(fn ->
        DesktopControl.register("jr-bob", "bob")
        send(test_pid, :bob_ready)

        receive do
          {:channel_push, _, _, "app_command", _} -> send(test_pid, :bob_got)
        after
          1_000 -> send(test_pid, :bob_none)
        end
      end)

    assert_receive :bob_ready, 1_000
    DesktopControl.register("jr-alice", "alice")

    {:ok, n} = DesktopControl.command("set_theme", %{"id" => "light"}, "alice")
    # only alice's shell counted (bob's tenant differs)
    assert n == 1

    assert_receive {:channel_push, "jr-alice", _, "app_command", _}, 1_000
    assert_receive :bob_none, 2_000
    refute_received :bob_got
    Process.exit(bob, :kill)
  end

  test "a nil-tenant caller reaches all shells (grandfather/dev)" do
    DesktopControl.register("jr-dev", "alice")
    {:ok, n} = DesktopControl.command("set_theme", %{"id" => "x"}, nil)
    assert n >= 1
    assert_receive {:channel_push, "jr-dev", _, "app_command", _}, 1_000
  end
end
