defmodule Workbooks.Desktop.TsiTcp do
  @moduledoc """
  ThousandIsland TCP transport with a polling accept, for the in-container
  control plane under krunvm (wb-ryw).

  libkrun's TSI serializes guest socket control operations behind a parked
  blocking `accept`: while an acceptor sits in `:gen_tcp.accept/1`
  (infinity), every other socket op — `sockname`, `peername`, `setopts`,
  even reads on established connections — queues until the NEXT connection
  arrives. Stock ThousandIsland parks exactly such an accept, so Bandit's
  startup `listener_info` blocked forever (the boot hang) and each request
  was served one-connection-behind (empty replies).

  Polling `accept` with a short timeout releases the channel every cycle so
  queued ops flush. Proven in-guest: stock TI serves nothing; this transport
  answers in <1s. Everything but `accept/1` delegates to the stock transport.
  """

  alias ThousandIsland.Transports.TCP

  @accept_poll_ms 250

  defdelegate listen(port, opts), to: TCP

  def accept(listener_socket) do
    case :gen_tcp.accept(listener_socket, @accept_poll_ms) do
      {:error, :timeout} -> accept(listener_socket)
      other -> other
    end
  end

  defdelegate handshake(socket), to: TCP
  defdelegate upgrade(socket, opts), to: TCP
  defdelegate controlling_process(socket, pid), to: TCP
  defdelegate recv(socket, length, timeout), to: TCP
  defdelegate send(socket, data), to: TCP
  defdelegate sendfile(socket, filename, offset, length), to: TCP
  defdelegate getopts(socket, options), to: TCP
  defdelegate setopts(socket, options), to: TCP
  defdelegate shutdown(socket, way), to: TCP
  defdelegate close(socket), to: TCP
  defdelegate sockname(socket), to: TCP
  defdelegate peername(socket), to: TCP
  defdelegate peercert(socket), to: TCP
  defdelegate secure?(), to: TCP
  defdelegate getstat(socket), to: TCP
  defdelegate negotiated_protocol(socket), to: TCP
  defdelegate connection_information(socket), to: TCP
end
