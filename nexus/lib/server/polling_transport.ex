defmodule Nexus.Server.PollingTransport do
  @moduledoc """
  A ThousandIsland transport identical to `ThousandIsland.Transports.TCP` EXCEPT it accepts with a
  short timeout in a loop instead of a parked, infinite blocking `accept/1`.

  ## Why

  Under **libkrun TSI** (the macOS microVM networking the local `work deploy` path uses, krunvm
  0.2.6), all guest socket control ops serialize behind a parked blocking `accept()`: while one
  acceptor sits in `:gen_tcp.accept(listener)` (infinity), a `getsockname`/`setsockopt`/even reads on
  established connections queue behind it and only flush when the NEXT connection completes the
  accept. Bandit/ThousandIsland call `sockname` on the listener right after bind → it deadlocks on an
  idle listener (boot hangs), and under load every request runs "one connection behind" (empty
  replies). Root-caused + the fix proven by our own spike — see
  `desktop/scripts/engine-spike/upstream-issues.md` #2.

  The fix (theirs, verified "answers instantly"): replace the parked accept with a `accept(_, 250ms)`
  poll loop, so the TSI op-queue flushes ~4×/s regardless of traffic. Harmless off-TSI (a timed
  accept is a cheap syscall); ThousandIsland sees a normal blocking accept that returns when a
  connection arrives — the polling is internal.

  Everything other than `accept/1` delegates to `ThousandIsland.Transports.TCP`.
  """
  @behaviour ThousandIsland.Transport

  alias ThousandIsland.Transports.TCP

  # Poll cadence: short enough to keep TSI's serialized op-queue flushing promptly, long enough that
  # idle acceptors cost ~nothing. Our spike used 250ms.
  @poll_ms 250

  @impl ThousandIsland.Transport
  def accept(listener_socket) do
    case :gen_tcp.accept(listener_socket, @poll_ms) do
      # No connection within the window — loop. This periodic return is the whole point: it releases
      # the TSI socket-op queue. ThousandIsland never sees the :timeout; to it this is a blocking accept.
      {:error, :timeout} -> accept(listener_socket)
      other -> other
    end
  end

  # ── everything else is plain TCP ────────────────────────────────────────────────────────────────
  @impl ThousandIsland.Transport
  defdelegate listen(port, options), to: TCP
  @impl ThousandIsland.Transport
  defdelegate handshake(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate upgrade(socket, options), to: TCP
  @impl ThousandIsland.Transport
  defdelegate controlling_process(socket, pid), to: TCP
  @impl ThousandIsland.Transport
  defdelegate recv(socket, length, timeout), to: TCP
  @impl ThousandIsland.Transport
  defdelegate send(socket, data), to: TCP
  @impl ThousandIsland.Transport
  defdelegate sendfile(socket, filename, offset, length), to: TCP
  @impl ThousandIsland.Transport
  defdelegate getopts(socket, options), to: TCP
  @impl ThousandIsland.Transport
  defdelegate setopts(socket, options), to: TCP
  @impl ThousandIsland.Transport
  defdelegate shutdown(socket, way), to: TCP
  @impl ThousandIsland.Transport
  defdelegate close(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate sockname(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate peername(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate peercert(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate secure?(), to: TCP
  @impl ThousandIsland.Transport
  defdelegate getstat(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate negotiated_protocol(socket), to: TCP
  @impl ThousandIsland.Transport
  defdelegate connection_information(socket), to: TCP
end
