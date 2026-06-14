defmodule Workbooks.EnvBrokerTest do
  @moduledoc """
  The agent→user env-prompt request/response cycle (wb-kbq5.2), tested in
  isolation: the two Registries carry it, no socket/app needed. We stand in for
  the desktop shell with the test process and assert the full round-trip —
  request blocks, the prompt is pushed, fulfill wakes the caller with the value.
  """
  # async: false — uses the app's globally-named EnvBroker Registries (started by
  # the supervision tree). Each test cleans up its own socket registration.
  use ExUnit.Case, async: false

  alias Workbooks.EnvBroker

  test "no connected shell → {:error, :no_desktop}" do
    # No socket registered for this process → not subscribed.
    refute EnvBroker.desktop_subscribed?()
    assert EnvBroker.request("OPENAI_API_KEY", "to call the API", 200) == {:error, :no_desktop}
  end

  test "full round-trip: request pushes a prompt, fulfill returns the value" do
    # Stand in for the desktop shell — register THIS process as a socket.
    EnvBroker.register_socket("jr-1")
    assert EnvBroker.desktop_subscribed?()

    parent = self()

    # request/3 blocks, so run it in a task; capture its result.
    task = Task.async(fn -> EnvBroker.request("STRIPE_KEY", "to charge", 2_000) end)

    # The broker pushes the prompt to the registered socket (us) as a
    # {:channel_push, join_ref, topic, event, payload} message.
    request_id =
      receive do
        {:channel_push, "jr-1", "engine:env_prompt", "env_prompt", payload} ->
          assert payload["name"] == "STRIPE_KEY"
          assert payload["reason"] == "to charge"
          assert is_binary(payload["request_id"])
          payload["request_id"]
      after
        1_000 -> flunk("no env_prompt pushed")
      end

    # The user "provides" the value.
    assert :ok == EnvBroker.fulfill(request_id, "sk_live_xxx")

    assert Task.await(task, 2_000) == {:ok, "sk_live_xxx"}
    _ = parent
  end

  test "cancel wakes the caller with {:error, :cancelled}" do
    EnvBroker.register_socket("jr-2")
    task = Task.async(fn -> EnvBroker.request("X", nil, 2_000) end)

    request_id =
      receive do
        {:channel_push, _, _, "env_prompt", p} -> p["request_id"]
      after
        1_000 -> flunk("no prompt")
      end

    assert :ok == EnvBroker.cancel(request_id)
    assert Task.await(task, 2_000) == {:error, :cancelled}
  end

  test "request times out when never answered" do
    EnvBroker.register_socket("jr-3")
    assert EnvBroker.request("Y", nil, 150) == {:error, :timeout}
  end

  test "fulfill for an unknown request_id is a no-op error" do
    assert EnvBroker.fulfill("does-not-exist", "v") == :error
  end
end
