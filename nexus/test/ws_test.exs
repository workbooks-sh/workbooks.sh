defmodule Nexus.WsTest do
  @moduledoc "The WebSocket live-channel handler — protocol logic (subscribe → stream, ping, identity injection)."
  use ExUnit.Case, async: false

  setup do
    # A fake Live source that echoes the injected identity + a final event, so we can assert the handler
    # runs the source, injects tenant/user, and pushes each emitted event back as a frame.
    Nexus.Live.register("ws_test_echo", fn params, emit ->
      emit.(%{type: "text", tenant: params["tenant"], user: params["u"], got: params["x"]})
      emit.(%{type: "final"})
      :ok
    end)

    :ok
  end

  defp drain(n), do: for(_ <- 1..n, do: (receive do {:ws_event, ev} -> ev after 1000 -> flunk("no ws_event") end))

  test "subscribe runs the source with SERVER-injected identity; events stream back as frames" do
    {:ok, st} = Nexus.Ws.init(%{tenant: "org_real", user: "usr_42"})

    # A client tries to spoof tenant in params — the handler must overwrite it with the socket identity.
    msg = Jason.encode!(%{op: "subscribe", source: "ws_test_echo", params: %{"x" => "hi", "tenant" => "org_attacker"}})
    assert {:ok, st} = Nexus.Ws.handle_in({msg, [opcode: :text]}, st)
    assert is_pid(st.runner)

    # The runner emits to self() as {:ws_event, ev}; handle_info pushes each as a text frame.
    [e1, e2, e3] = drain(3)
    assert e1.tenant == "org_real" and e1.user == "usr_42" and e1.got == "hi"
    assert e2.type == "final"
    assert e3.type == "done"

    assert {:push, {:text, frame}, ^st} = Nexus.Ws.handle_info({:ws_event, e1}, st)
    assert Jason.decode!(frame)["tenant"] == "org_real"
  end

  test "ping → pong; junk → error frame" do
    {:ok, st} = Nexus.Ws.init(%{tenant: "t", user: "u"})
    assert {:push, {:text, p}, ^st} = Nexus.Ws.handle_in({Jason.encode!(%{op: "ping"}), [opcode: :text]}, st)
    assert Jason.decode!(p)["type"] == "pong"

    assert {:push, {:text, e}, ^st} = Nexus.Ws.handle_in({"not json", [opcode: :text]}, st)
    assert Jason.decode!(e)["type"] == "error"
  end

  test "nil user defaults to anon (no crash)" do
    {:ok, st} = Nexus.Ws.init(%{tenant: "t", user: nil})
    msg = Jason.encode!(%{op: "subscribe", source: "ws_test_echo", params: %{}})
    assert {:ok, _} = Nexus.Ws.handle_in({msg, [opcode: :text]}, st)
    [e1 | _] = drain(1)
    assert e1.user == "anon"
  end
end
