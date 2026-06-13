defmodule Workbooks.Reclaim.RsyncTest do
  @moduledoc """
  RECLAIM (durable) — `rsync` (daemon-protocol client).

  resolved.json reclaim recipe: rsync's port-873 daemon protocol is a line/binary handshake a client speaks
  over a one-shot TCP transport — send the client greeting `@RSYNCD: <ver>\n`, then `#list\n` for module
  enumeration. The host opens the SSRF-pinned socket; the guest never does. This reproduces the rsync DAEMON
  CLIENT (version handshake + module listing) against a real public rsync daemon.

  This test is SELF-CONTAINED: it registers its own raw-TCP `:pynet` tool inline (`:tcp_allow`), not via
  Workbooks.BrokeredTools.

  What it proves empirically:
    - a real rsync-daemon protocol exchange happens over the brokered TCP transport: the server's
      `@RSYNCD: <ver>` greeting is received and a `#list` enumeration returns module lines + `@RSYNCD: EXIT`.

  HONEST SCOPE: this is the rsync DAEMON-PROTOCOL CLIENT (handshake + module enumeration) — NOT a full file-
  transfer delta codec (rolling-checksum/MD5 block matching) and NOT rsync-over-ssh. Those are additional
  client-side code over the same one-shot TCP primitive, exactly as the reclaim recipe states.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  # raw one-shot TCP: read stdin (the client greeting + `#list\n`), send to HOST PORT, write the daemon's
  # response to stdout. Registered INLINE so the test is self-contained.
  @tcp ~S"""
  import sys
  if len(sys.argv) < 3:
      sys.stderr.write("usage: rsyncd HOST PORT\n"); sys.exit(2)
  host = sys.argv[1]
  port = int(sys.argv[2])
  data = sys.stdin.buffer.read()
  try:
      resp = wb_tcp(host, port, data)
      sys.stdout.buffer.write(resp); sys.exit(0)
  except OSError as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("reclaim-rsyncd", @tcp, :argv, %{tcp_allow: true})
    :ok
  end

  # public rsync daemons to try (handshake + #list); first reachable one that speaks @RSYNCD wins.
  @daemons [
    {"rsync.gentoo.org", 873},
    {"mirror.csclub.uwaterloo.ca", 873},
    {"ftp.halifax.rwth-aachen.de", 873},
    {"mirrors.kernel.org", 873}
  ]

  # client greeting: announce a protocol version, then ask for the module list. The daemon replies with its
  # own `@RSYNCD: <ver>` line, the module listing, then `@RSYNCD: EXIT`.
  @greeting "@RSYNCD: 31.0\n#list\n"

  @tag :netdeps
  @tag timeout: 180_000
  test "rsync daemon protocol: @RSYNCD handshake + module enumeration over brokered TCP" do
    {host, out} =
      Enum.reduce_while(@daemons, nil, fn {h, p}, _acc ->
        case CommandRegistry.run_status("reclaim-rsyncd", @greeting, [h, Integer.to_string(p)]) do
          {:ok, body, 0} ->
            if body =~ "@RSYNCD:" do
              {:halt, {h, body}}
            else
              {:cont, nil}
            end

          _ ->
            {:cont, nil}
        end
      end)
      |> case do
        nil -> flunk("no public rsync daemon reachable for handshake (network/daemon availability)")
        ok -> ok
      end

    # real rsync daemon greeting was received (version handshake)
    assert out =~ ~r/@RSYNCD: \d+/, "expected @RSYNCD version greeting from #{host}, got:\n#{out}"
    # `#list` enumeration terminates with the protocol's EXIT sentinel -> a real module listing happened
    assert out =~ "@RSYNCD: EXIT", "expected module-list EXIT sentinel from #{host}, got:\n#{out}"
  end
end
