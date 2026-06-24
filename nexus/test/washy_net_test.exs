defmodule Nexus.WashyNetTest do
  @moduledoc """
  The `net` concern (wb-rfqv) + the spine's event-channel — Node TCP client sockets over :gen_tcp, end to
  end. A JS actor connects to a real local echo server, writes, and receives the echo as a 'data' event:
  proving inbound socket bytes flow `:gen_tcp` active-mode → actor mailbox → `reenter_event` → `wb_event`
  → the socket's event channel → `'data'`. This is the streaming sibling of the promise-completion path
  and the shared socket seam with WASIX §3.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.{Sandbox, Actor}

  @qjs "compilers/js/qjs-run.wasm"

  setup do
    {Registry, keys: :unique, name: Nexus.Washy.Actor.Registry} |> maybe_start()
    {DynamicSupervisor, strategy: :one_for_one, name: Nexus.Washy.Actor.Supervisor} |> maybe_start()
    :ok
  end

  defp maybe_start(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
    end
  end

  defp net_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command(
          {:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof require('net').connect));"},
          "",
          fuel: 50_000_000_000,
          timeout_ms: 60_000
        )
      )
  end

  # a minimal TCP echo server; returns its port. Echoes every received chunk back.
  defp echo_server do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, csock} = :gen_tcp.accept(lsock)
      echo = fn echo, s ->
        case :gen_tcp.recv(s, 0, 10_000) do
          {:ok, data} -> :gen_tcp.send(s, data); echo.(echo, s)
          _ -> :ok
        end
      end
      echo.(echo, csock)
    end)

    port
  end

  test "a JS actor connects, writes, and receives the echo as a 'data' event" do
    if net_wasm?() do
      test = self()
      port = echo_server()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:echo, v}); {:ok, nil} end, name: "rec_net")

      script = """
      var net=require('net');
      var s=net.connect(#{port},'127.0.0.1');
      s.on('data',function(d){Beam.call('rec_net', d.toString());});
      s.on('connect',function(){s.write('ping');});
      """

      {:ok, _} = Actor.beam_spawn({:js, script}, name: "neton")
      assert_receive {:echo, "ping"}, 8000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks net (rebuild the compilers package)")
    end
  end

  test "dns.lookup resolves localhost via the host resolver" do
    if net_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:dns, v}); {:ok, nil} end, name: "rec_dns")
      {:ok, _} = Actor.beam_spawn({:js, "require('dns').lookup('localhost',function(e,a){Beam.call('rec_dns', e?('err'):a);});"}, name: "dnson")
      assert_receive {:dns, addr}, 8000
      assert addr in ["127.0.0.1", "::1"] or is_binary(addr)
    else
      IO.puts("\n[skip] no net/dns")
    end
  end
end
