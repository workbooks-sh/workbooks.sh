defmodule Nexus.WashyWorkerTest do
  @moduledoc """
  wb-hwsp — node:worker_threads / node:child_process map a worker to another supervised JS actor; IPC
  rides the Beam mailbox. Proves the on-thesis "a worker IS a supervised BEAM process" model: a parent
  guest spawns a worker guest, posts it a message, the worker (with parentPort + workerData) echoes back,
  and the parent's worker.on('message') fires.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.{Sandbox, Actor}

  @qjs "compilers/js/qjs-run.wasm"

  setup do
    {Registry, keys: :unique, name: Nexus.Washy.Actor.Registry} |> maybe_start()
    {DynamicSupervisor, strategy: :one_for_one, name: Nexus.Washy.Actor.Supervisor} |> maybe_start()

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

  defp worker_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command({:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof require('worker_threads').Worker));"}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
      )
  end

  test "a worker_threads.Worker round-trips a message + workerData" do
    if worker_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:wt, v}); {:ok, nil} end, name: "wtrec")

      worker_src = "var p=require('worker_threads').parentPort; p.on('message',function(m){ p.postMessage('echo:'+m+':wd='+require('worker_threads').workerData.tag); });"

      main = """
      var wt=require('worker_threads');
      var w=new wt.Worker(#{inspect(worker_src)}, {workerData:{tag:'T'}});
      w.on('message',function(m){ Beam.call('wtrec', m); });
      w.postMessage('ping');
      """

      {:ok, _} = Actor.beam_spawn({:js, main}, name: "wtmain")
      assert_receive {:wt, "echo:ping:wd=T"}, 20_000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks worker_threads")
    end
  end
end
