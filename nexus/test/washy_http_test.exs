defmodule Nexus.WashyHttpTest do
  @moduledoc """
  The `http` client (wb-53d1) end to end: a JS actor does http.get against a real local HTTP server
  (a tiny :gen_tcp responder), receives the response, and reads statusCode + body — over node:net +
  node:stream, no new host seam. The Wave-2 keystone's client half.
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

  defp http_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command(
          {:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof require('http').get));"},
          "",
          fuel: 50_000_000_000,
          timeout_ms: 60_000
        )
      )
  end

  # a one-shot HTTP/1.1 server: reads the request, returns `body` with a Content-Length. Returns its port.
  defp http_server(body) do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(lsock)
      {:ok, _req} = :gen_tcp.recv(c, 0, 10_000)
      resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
      :gen_tcp.send(c, resp)
      :gen_tcp.close(c)
    end)

    port
  end

  test "http.get receives status + headers + body from a real server" do
    if http_wasm?() do
      test = self()
      port = http_server("hello world")
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:http, v}); {:ok, nil} end, name: "rec_http")

      script = """
      var http=require('http');
      http.get({host:'127.0.0.1',port:#{port},path:'/'},function(res){
        var body='';
        res.on('data',function(d){body+=d.toString();});
        res.on('end',function(){Beam.call('rec_http', res.statusCode+'|'+res.headers['content-type']+'|'+body);});
      });
      """

      {:ok, _} = Actor.beam_spawn({:js, script}, name: "httpc")
      assert_receive {:http, "200|text/plain|hello world"}, 8000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks http (rebuild the compilers package)")
    end
  end
end
