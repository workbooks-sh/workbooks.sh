defmodule Workbooks.WorkgateBrokerTest do
  @moduledoc """
  The agent→user capability-approval cycle (wb-kbq5.3), tested in isolation —
  parallel to EnvBrokerTest. The two Registries carry it, no socket/app needed;
  the test process stands in for the desktop shell and asserts the full
  Allow/Deny round-trip plus the no-desktop / timeout / unknown-id edges.
  """
  use ExUnit.Case, async: false

  alias Workbooks.WorkgateBroker

  test "no connected shell → {:error, :no_desktop}" do
    refute WorkgateBroker.desktop_subscribed?()
    assert WorkgateBroker.request("camera", "scan a QR", 200) == {:error, :no_desktop}
  end

  test "round-trip ALLOW: request pushes the prompt, permit('allow') unblocks with :allow" do
    WorkgateBroker.register_socket("jr-a")
    assert WorkgateBroker.desktop_subscribed?()

    task = Task.async(fn -> WorkgateBroker.request("camera", "scan a QR", 2_000) end)

    request_id =
      receive do
        {:channel_push, "jr-a", "workgate:control", "workgate_request", payload} ->
          assert payload["capability"] == "camera"
          assert payload["reason"] == "scan a QR"
          assert payload["policy_decision"] == "prompt_user"
          assert is_binary(payload["request_id"])
          payload["request_id"]
      after
        1_000 -> flunk("no workgate_request pushed")
      end

    assert :ok == WorkgateBroker.permit(request_id, "allow")
    assert Task.await(task, 2_000) == :allow
  end

  test "round-trip DENY: permit('deny') unblocks with :deny" do
    WorkgateBroker.register_socket("jr-d")
    task = Task.async(fn -> WorkgateBroker.request("microphone", nil, 2_000) end)

    request_id =
      receive do
        {:channel_push, _, _, "workgate_request", p} -> p["request_id"]
      after
        1_000 -> flunk("no prompt")
      end

    assert :ok == WorkgateBroker.permit(request_id, "deny")
    assert Task.await(task, 2_000) == :deny
  end

  test "an unrecognized decision string is treated as deny (fail-safe)" do
    WorkgateBroker.register_socket("jr-x")
    task = Task.async(fn -> WorkgateBroker.request("filesystem", nil, 2_000) end)

    request_id =
      receive do
        {:channel_push, _, _, "workgate_request", p} -> p["request_id"]
      after
        1_000 -> flunk("no prompt")
      end

    # anything that isn't "allow"/:allow must NOT grant — defaults to :deny
    assert :ok == WorkgateBroker.permit(request_id, "maybe")
    assert Task.await(task, 2_000) == :deny
  end

  test "request times out when never answered" do
    WorkgateBroker.register_socket("jr-t")
    assert WorkgateBroker.request("network", nil, 150) == {:error, :timeout}
  end

  test "permit for an unknown request_id is a no-op error" do
    assert WorkgateBroker.permit("wg-does-not-exist", "allow") == :error
  end
end
