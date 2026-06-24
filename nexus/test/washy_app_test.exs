defmodule Nexus.WashyAppTest do
  @moduledoc """
  COMPOSITION proof — the modules are not just individually green, they compose into a real app inside ONE
  dense, supervised JS actor: an HTTP server that per request reads a file (fs), hashes it (crypto), parses
  the query string (querystring), and returns JSON (http + buffer). A real TCP client drives it. This is the
  "runs a real app, NIF-free" milestone and the integration forcing-function for Wave-2.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.{Sandbox, Actor}

  @qjs "compilers/js/qjs-run.wasm"

  setup do
    {Registry, keys: :unique, name: Nexus.Washy.Actor.Registry} |> maybe_start()
    {DynamicSupervisor, strategy: :one_for_one, name: Nexus.Washy.Actor.Supervisor} |> maybe_start()
    # the Actor supervisor is app-owned (persists across test runs) — kill any actors a prior run left, so
    # re-using a registered name doesn't resolve to a stale actor bound to a dead test process.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Nexus.Washy.Actor.Supervisor),
        do: DynamicSupervisor.terminate_child(Nexus.Washy.Actor.Supervisor, pid)

    :ok
  end

  defp maybe_start(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
    end
  end

  defp recv_all(c, acc \\ "") do
    case :gen_tcp.recv(c, 0, 8000) do
      {:ok, data} -> recv_all(c, acc <> data)
      {:error, _} -> acc
    end
  end

  defp app_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command(
          {:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof require('http').createServer));"},
          "",
          fuel: 50_000_000_000,
          timeout_ms: 60_000
        )
      )
  end

  test "an http+fs+crypto+querystring app runs as one JS actor and serves a real client" do
    if app_wasm?() do
      test = self()
      payload = "washy-payload"
      expected_sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

      {:ok, _} = Actor.beam_spawn(fn [p], _ -> send(test, {:port, p}); {:ok, nil} end, name: "apprec")

      script = """
      var http=require('http'), fs=require('fs'), crypto=require('crypto'), qs=require('querystring');
      var server=http.createServer(function(req,res){
        var path=req.url.split('?')[0];
        var query=qs.parse(req.url.split('?')[1]||'');
        if(path==='/hash'){
          fs.writeFileSync('/work/data.txt','#{payload}');
          var data=fs.readFileSync('/work/data.txt','utf8');
          var sha=crypto.createHash('sha256').update(data).digest('hex');
          res.writeHead(200,{'Content-Type':'application/json'});
          res.end(JSON.stringify({path:path, x:query.x, len:data.length, sha256:sha}));
        } else { res.writeHead(404,{'Content-Type':'text/plain'}); res.end('not found'); }
      });
      server.listen(0,function(){Beam.call('apprec', server.address().port);});
      """

      {:ok, _} = Actor.beam_spawn({:js, script}, name: "appsrv")
      assert_receive {:port, port}, 8000

      {:ok, c} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
      :ok = :gen_tcp.send(c, "GET /hash?x=42 HTTP/1.1\r\nHost: x\r\n\r\n")
      resp = recv_all(c)
      :gen_tcp.close(c)

      assert resp =~ "200 OK"
      assert resp =~ "application/json"
      [_head, body] = String.split(resp, "\r\n\r\n", parts: 2)
      json = Jason.decode!(body)
      assert json["path"] == "/hash"
      assert json["x"] == "42"
      assert json["len"] == byte_size(payload)
      assert json["sha256"] == expected_sha
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the http app modules")
    end
  end
end
