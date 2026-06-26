defmodule Nexus.LiveChatSyncTest do
  @moduledoc """
  G1 — the **end-to-end chat round-trip** over a REAL WebSocket against a REAL Bandit server, the
  contract every other live surface builds on. Boots the actual `dogfood/cloud` workbook (so its
  `server.register/0` registers the `"msgs"`/`"reactions"`/`"cursors"` shapes) in multi-tenant
  `auth=Cloud`, then drives raw RFC-6455 sockets — no mock, no `Plug.Test`, no handler-poking.

  Two clients in the SAME org subscribe to a channel's `msgs` shape; a third in a DIFFERENT org
  subscribes to the same channel name. A `Store.create(Message)` in org_a must reach BOTH org_a
  sockets as a `shape:delta` and reach the org_b socket NOT AT ALL (tenant partition). We then cover
  edit (`:update`), delete (`:delete`), a reaction, and a read-cursor — the full chat shape surface.

  The WS client is a tiny gen_tcp RFC-6455 implementation (mask client→server frames, parse the
  unmasked server→client frames) so the runtime gains no websocket-client dependency for a test.
  """
  use ExUnit.Case, async: false
  import Bitwise
  @moduletag :integration
  @moduletag timeout: 120_000

  @port 4097
  @host ~c"127.0.0.1"

  setup_all do
    if System.find_executable("git") do
      prev_auth = Application.get_env(:nexus, :auth)
      Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)
      System.put_env("WB_CONTROL_PLANE", "1")
      System.put_env("NEXUS_TENANT", "org_a")

      base = Path.join(System.tmp_dir!(), "wb-livechat-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      prev_data = System.get_env("WB_DATA")
      System.put_env("WB_DATA", base)

      cloud_root = Path.expand("../dogfood/cloud", File.cwd!())

      Nexus.ControlPlane.reset()
      Nexus.Auth.TokenStore.ensure(:cp_tokens)

      {:ok, pid} = Nexus.Server.start_link(root: cloud_root, port: @port)
      wait_health()

      # register/0 ran during bringup → the chat shapes resolve. Pull the real compiled module from the
      # allowlist (the test never aliases the workbook's Message struct itself).
      {msg_mod, :channel} = Nexus.Shapes.resolve("msgs")
      {reaction_mod, :message} = Nexus.Shapes.resolve("reactions")
      {cursor_mod, :channel} = Nexus.Shapes.resolve("cursors")

      a1 = Nexus.ControlPlane.Token.mint("org_a", "a1", role: "owner", user: "a1@t").token
      a2 = Nexus.ControlPlane.Token.mint("org_a", "a2", role: "owner", user: "a2@t").token
      b1 = Nexus.ControlPlane.Token.mint("org_b", "b1", role: "owner", user: "b1@t").token

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        if prev_auth, do: Application.put_env(:nexus, :auth, prev_auth), else: Application.delete_env(:nexus, :auth)
        if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
        System.delete_env("WB_CONTROL_PLANE")
        System.delete_env("NEXUS_TENANT")
        File.rm_rf(base)
      end)

      {:ok, msg_mod: msg_mod, reaction_mod: reaction_mod, cursor_mod: cursor_mod, a1: a1, a2: a2, b1: b1}
    else
      {:ok, skip: true}
    end
  end

  setup ctx do
    unless ctx[:skip] do
      Nexus.Store.clear(ctx.msg_mod, "org_a")
      Nexus.Store.clear(ctx.msg_mod, "org_b")
      Nexus.Store.clear(ctx.reaction_mod, "org_a")
      Nexus.Store.clear(ctx.cursor_mod, "org_a")
    end

    :ok
  end

  test "a message round-trips to same-org subscribers and NEVER crosses the tenant boundary", ctx do
    skipping?(ctx) && throw(:skip)

    a1 = ws_subscribe(ctx.a1, "msgs", "general")
    a2 = ws_subscribe(ctx.a2, "msgs", "general")
    b1 = ws_subscribe(ctx.b1, "msgs", "general")

    # Each subscribe replies with an (empty) snapshot first.
    assert %{"type" => "shape:init", "name" => "msgs", "rows" => []} = recv_json(a1)
    assert %{"type" => "shape:init", "rows" => []} = recv_json(a2)
    assert %{"type" => "shape:init", "rows" => []} = recv_json(b1)

    # INSERT — the durable write fans a delta to every matching same-tenant socket.
    {:ok, _} =
      Nexus.Store.create(ctx.msg_mod, %{channel: "general", author: "a1@t", body: "hi team", parent: "", ts: 1}, "org_a")

    assert %{"type" => "shape:delta", "name" => "msgs", "op" => "insert", "row" => %{"body" => "hi team"}} = recv_json(a1)
    assert %{"type" => "shape:delta", "op" => "insert", "row" => %{"body" => "hi team"}} = recv_json(a2)
    # The cross-tenant socket must hear NOTHING from an org_a write.
    refute_frame(b1)

    # A write to a DIFFERENT channel must not reach a "general" subscriber (filter predicate).
    {:ok, _} =
      Nexus.Store.create(ctx.msg_mod, %{channel: "random", author: "a1@t", body: "elsewhere", parent: "", ts: 2}, "org_a")

    refute_frame(a1)

    # UPDATE (edit) — a coarse :update delta carrying the changed field.
    :ok = Nexus.Store.update(ctx.msg_mod, %{body: "hi team"}, %{body: "hi team (edited)"}, "org_a")
    assert %{"type" => "shape:delta", "op" => "update", "row" => %{"body" => "hi team (edited)"}} = recv_json(a1)
    assert %{"op" => "update"} = recv_json(a2)
    refute_frame(b1)

    # DELETE — a :delete delta carrying the removed row.
    :ok = Nexus.Store.delete(ctx.msg_mod, %{body: "hi team (edited)"}, "org_a")
    assert %{"type" => "shape:delta", "op" => "delete", "row" => %{"body" => "hi team (edited)"}} = recv_json(a1)
    assert %{"op" => "delete"} = recv_json(a2)
    refute_frame(b1)

    Enum.each([a1, a2, b1], &ws_close/1)
  end

  test "reactions and read cursors are their own live shapes on the same transport", ctx do
    skipping?(ctx) && throw(:skip)

    rx = ws_subscribe(ctx.a1, "reactions", "m1")
    cur = ws_subscribe(ctx.a2, "cursors", "general")
    assert %{"type" => "shape:init"} = recv_json(rx)
    assert %{"type" => "shape:init"} = recv_json(cur)

    {:ok, _} = Nexus.Store.create(ctx.reaction_mod, %{message: "m1", emoji: "🔥", author: "a1@t", ts: 9}, "org_a")
    assert %{"op" => "insert", "row" => %{"emoji" => "🔥", "message" => "m1"}} = recv_json(rx)
    # A reaction on a DIFFERENT message must not reach the m1 subscriber.
    {:ok, _} = Nexus.Store.create(ctx.reaction_mod, %{message: "m2", emoji: "👍", author: "a1@t", ts: 10}, "org_a")
    refute_frame(rx)

    {:ok, _} = Nexus.Store.create(ctx.cursor_mod, %{channel: "general", user: "a2@t", ts: 42}, "org_a")
    assert %{"op" => "insert", "row" => %{"channel" => "general", "ts" => 42}} = recv_json(cur)

    Enum.each([rx, cur], &ws_close/1)
  end

  test "reconnect after a mid-stream drop re-snapshots to the authoritative set — no gaps, no dupes (G6)", ctx do
    skipping?(ctx) && throw(:skip)

    a1 = ws_subscribe(ctx.a1, "msgs", "general")
    assert %{"type" => "shape:init", "rows" => []} = recv_json(a1)

    {:ok, _} = Nexus.Store.create(ctx.msg_mod, %{channel: "general", author: "a1@t", body: "m1", parent: "", ts: 1}, "org_a")
    assert %{"op" => "insert", "row" => %{"body" => "m1"}} = recv_json(a1)

    # Kill the socket mid-stream (a dropped connection / kill-9). The server-side subscription dies with
    # the socket process; no client is listening now.
    ws_close(a1)

    # Writes land while the client is disconnected — these are the deltas it "missed".
    {:ok, _} = Nexus.Store.create(ctx.msg_mod, %{channel: "general", author: "a1@t", body: "m2-missed", parent: "", ts: 2}, "org_a")
    :ok = Nexus.Store.update(ctx.msg_mod, %{body: "m1"}, %{body: "m1-edited-offline"}, "org_a")

    # Reconnect (a fresh socket) and re-subscribe to the same shape.
    a1b = ws_subscribe(ctx.a1, "msgs", "general")
    init = recv_json(a1b)

    assert init["type"] == "shape:init"
    bodies = init["rows"] |> Enum.map(& &1["body"]) |> Enum.sort()
    # NO GAPS: the catch-up snapshot holds the authoritative current set — the missed insert AND the
    # offline edit are both present. NO DUPES: m1 appears exactly once (as its edited value), never twice.
    assert bodies == ["m1-edited-offline", "m2-missed"], "reconnect snapshot was not the authoritative set: #{inspect(bodies)}"

    # And the live feed resumes cleanly on the new socket — one delta, not a replay of history.
    {:ok, _} = Nexus.Store.create(ctx.msg_mod, %{channel: "general", author: "a1@t", body: "m3-live", parent: "", ts: 3}, "org_a")
    assert %{"op" => "insert", "row" => %{"body" => "m3-live"}} = recv_json(a1b)
    refute_frame(a1b)

    ws_close(a1b)
  end

  test "re-subscribing the same shape on one socket does not double-deliver deltas (G6 no-dupes)", ctx do
    skipping?(ctx) && throw(:skip)

    sock = ws_subscribe(ctx.a1, "msgs", "general")
    assert %{"type" => "shape:init"} = recv_json(sock)

    # Narrow/refresh the SAME shape on the SAME socket — the prior subscription must be dropped, not stacked.
    :ok = send_text(sock, Jason.encode!(%{op: "shape", name: "msgs", scope: "general"}))
    assert %{"type" => "shape:init"} = recv_json(sock)

    {:ok, _} = Nexus.Store.create(ctx.msg_mod, %{channel: "general", author: "a1@t", body: "once", parent: "", ts: 1}, "org_a")
    assert %{"op" => "insert", "row" => %{"body" => "once"}} = recv_json(sock)
    # If the re-subscribe had stacked, a SECOND identical delta would arrive here.
    refute_frame(sock)

    ws_close(sock)
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────────────

  defp skipping?(ctx), do: ctx[:skip] == true

  defp wait_health(n \\ 600) do
    Application.ensure_all_started(:inets)

    case :httpc.request(:get, {~c"http://127.0.0.1:#{@port}/health", []}, [{:timeout, 1000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ when n > 0 -> Process.sleep(200); wait_health(n - 1)
      _ -> flunk("cloud server never became healthy on :#{@port}")
    end
  end

  # Open a socket, do the RFC-6455 handshake carrying the Bearer PAT (no Origin → non-browser, allowed),
  # then send the shape subscribe op. Returns the connected socket.
  defp ws_subscribe(token, name, scope) do
    {:ok, sock} = :gen_tcp.connect(@host, @port, [:binary, active: false, packet: :raw], 5000)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET /ws HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{@port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Authorization: Bearer #{token}\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)
    :ok = read_handshake(sock)
    :ok = send_text(sock, Jason.encode!(%{op: "shape", name: name, scope: scope}))
    sock
  end

  # Read the 101 response up to the blank line that ends the headers.
  defp read_handshake(sock, acc \\ "") do
    {:ok, chunk} = :gen_tcp.recv(sock, 0, 5000)
    acc = acc <> chunk

    if String.contains?(acc, "\r\n\r\n") do
      assert acc =~ "101", "expected a 101 Switching Protocols upgrade, got:\n#{acc}"
      :ok
    else
      read_handshake(sock, acc)
    end
  end

  # Client→server frames MUST be masked (RFC-6455 §5.3). Single text frame, fin=1, opcode=0x1.
  defp send_text(sock, payload) do
    len = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)

    header =
      cond do
        len <= 125 -> <<0x81, 0x80 ||| len>>
        len <= 0xFFFF -> <<0x81, 0x80 ||| 126, len::16>>
        true -> <<0x81, 0x80 ||| 127, len::64>>
      end

    :gen_tcp.send(sock, [header, mask, mask_payload(payload, mask)])
  end

  defp mask_payload(payload, mask) do
    m = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> bxor(byte, Enum.at(m, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # Read one server→client TEXT frame as decoded JSON, skipping any control frames (ping/pong/close).
  defp recv_json(sock, timeout \\ 2000) do
    case recv_frame(sock, timeout) do
      {:text, payload} -> Jason.decode!(payload)
      {:control, _} -> recv_json(sock, timeout)
      :timeout -> flunk("expected a WS frame, got nothing within #{timeout}ms")
    end
  end

  # Assert NO data frame arrives (the tenant/filter boundary held).
  defp refute_frame(sock, timeout \\ 400) do
    case recv_frame(sock, timeout) do
      :timeout -> :ok
      {:control, _} -> refute_frame(sock, timeout)
      {:text, payload} -> flunk("unexpected delta leaked across the boundary: #{payload}")
    end
  end

  defp recv_frame(sock, timeout) do
    case :gen_tcp.recv(sock, 2, timeout) do
      {:ok, <<b0, b1>>} ->
        opcode = b0 &&& 0x0F
        len0 = b1 &&& 0x7F

        len =
          case len0 do
            126 -> {:ok, <<l::16>>} = :gen_tcp.recv(sock, 2, timeout); l
            127 -> {:ok, <<l::64>>} = :gen_tcp.recv(sock, 8, timeout); l
            l -> l
          end

        payload = if len > 0, do: (with({:ok, p} <- :gen_tcp.recv(sock, len, timeout), do: p)), else: ""
        if opcode == 0x1, do: {:text, payload}, else: {:control, opcode}

      {:error, :timeout} ->
        :timeout

      {:error, _} ->
        :timeout
    end
  end

  defp ws_close(sock), do: :gen_tcp.close(sock)
end
