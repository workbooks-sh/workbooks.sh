defmodule Nexus.Membrane.Server do
  @moduledoc """
  The **socket transport** for the Membrane (Phase 5 increment 2 / wb-g5w3) — a per-run loopback TCP
  listener that lets the in-sandbox shell `exec` a host capability MID-PIPE (`cat x | work parse`,
  `work check && ls`), not just as the first word. The wasmer guest reaches it over `--net` (proven:
  a guest connects to host `127.0.0.1` cleanly), an in-sandbox shim (`work`/`agent`/… on PATH) sends a
  framed request, and we dispatch through the SAME `Nexus.Membrane.handle_request/3` the first-word path
  uses — so a host cap behaves identically whichever transport delivered it.

  ## Wire protocol (one request/response per connection)

      <token>\\n<cmd>\\t<arg1>\\t…\\n<raw stdin…>

  Line 1 is a per-run secret TOKEN (any guest on the box has `--net`, so without it another run's guest
  could hit this socket — the token scopes the listener to ITS run). Line 2 + the remainder are exactly
  the `Nexus.Membrane` frame. The response is the host cap's output bytes; then the connection closes.

  Bound to ONE run's `vfs`+`perms` at start; loopback only; ephemeral port. Supervised, with the acceptor
  under the GenServer so the listen socket dies with the run.
  """
  use GenServer

  @doc "Start a per-run membrane socket bound to `vfs`/`perms`. Returns `{:ok, pid}`; query `port/1` + `token/1`."
  def start_link(vfs, perms, opts \\ []) do
    GenServer.start_link(__MODULE__, {vfs, perms}, opts)
  end

  @doc "The loopback TCP port the in-sandbox shim connects to."
  def port(server), do: GenServer.call(server, :port)

  @doc "The per-run secret the shim must send as line 1 (scopes the socket to this run)."
  def token(server), do: GenServer.call(server, :token)

  @doc "Stop the listener (closes the socket)."
  def stop(server), do: GenServer.stop(server, :normal)

  # ── GenServer ───────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init({vfs, perms}) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    parent = self()

    # Create the listen socket INSIDE the acceptor so it owns both the listen socket and every accepted
    # socket — only the owning process may accept/recv on a passive socket. Report the bound port back.
    acceptor =
      spawn_link(fn ->
        {:ok, lsock} =
          :gen_tcp.listen(0, [
            :binary,
            ip: {127, 0, 0, 1},
            packet: :raw,
            active: false,
            reuseaddr: true,
            backlog: 16,
            # The shim half-closes its WRITE side to signal end-of-request; with the default
            # exit_on_close:true, gen_tcp would then tear down the WHOLE socket on that EOF and our
            # response `send` fails with :closed. Keep the write side open so we can reply.
            exit_on_close: false
          ])

        {:ok, port} = :inet.port(lsock)
        send(parent, {:bound, port, lsock})
        accept_loop(lsock, vfs, perms, token, parent)
      end)

    receive do
      {:bound, port, lsock} ->
        {:ok, %{lsock: lsock, port: port, token: token, vfs: vfs, perms: perms, acceptor: acceptor}}
    after
      5_000 -> {:stop, :listen_timeout}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:token, _from, state), do: {:reply, state.token, state}

  @impl true
  def terminate(_reason, %{lsock: lsock}) do
    if lsock, do: :gen_tcp.close(lsock)
    :ok
  end

  # ── acceptor + per-connection handling ──────────────────────────────────────────────────────────

  defp accept_loop(lsock, vfs, perms, token, parent) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # Serve inline. Each request is one-shot + bounded, so a single acceptor is fine and avoids the
        # gen_tcp controlling-process handoff (only the accepting process may recv on a passive socket).
        serve(sock, vfs, perms, token)
        accept_loop(lsock, vfs, perms, token, parent)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(lsock, vfs, perms, token, parent)
    end
  end

  defp serve(sock, vfs, perms, token) do
    req = recv_all(sock, "")

    response =
      try do
        case String.split(req, "\n", parts: 2) do
          [^token, frame] -> Nexus.Membrane.handle_request(vfs, perms, frame)
          _ -> "membrane: unauthorized (bad or missing run token)"
        end
      rescue
        e -> "membrane: error — #{Exception.message(e)}"
      end

    :gen_tcp.send(sock, response)
    # shutdown(:write) sends our FIN (flushing the response); then close. (exit_on_close:false above kept
    # the socket writable after the client's half-close so this send/reply works at all.)
    :gen_tcp.shutdown(sock, :write)
    :gen_tcp.close(sock)
  end

  # Read until the guest half-closes its write side (one-shot request). Bounded so a guest that never
  # closes can't leak the process forever.
  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end
end
