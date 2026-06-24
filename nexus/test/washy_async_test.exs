defmodule Nexus.WashyAsyncTest do
  @moduledoc """
  The async spine's GENERIC promise-completion contract (wb-5q8w) — the path every async I/O module
  (fs/net/http) reuses. A guest shim calls __wb_async(arm) to get a Promise + a completion id; when the
  host op finishes, the owning actor re-enters the guest at wb_complete with the {id,ok,value} envelope,
  resolving (or rejecting) that promise. Here the test plays the role of the host op by calling
  Nexus.Washy.Actor.io_complete/4 directly — proving the resolve/reject re-entry independent of any
  specific I/O concern.
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

  defp async_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command(
          {:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof globalThis.__wb_async));"},
          "",
          fuel: 50_000_000_000,
          timeout_ms: 60_000
        )
      )
  end

  test "io_complete resolves the guest promise the host op was waiting on" do
    if async_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:c, v}); {:ok, nil} end, name: "rec_c")
      # at boot the guest allocates completion id 1 (first __wb_async) and awaits it
      {:ok, pid} = Actor.beam_spawn({:js, "__wb_async(function(id){}).then(function(v){Beam.call('rec_c',v);});"}, name: "asy")

      # play the host op: resolve completion 1 with a value → wb_complete re-entry → promise .then → Beam.call
      Actor.io_complete(pid, 1, "hello")
      assert_receive {:c, "hello"}, 5000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks __wb_async (rebuild the compilers package)")
    end
  end

  test "io_complete with ok?: false rejects the promise" do
    if async_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:e, v}); {:ok, nil} end, name: "rec_e")
      {:ok, pid} = Actor.beam_spawn({:js, "__wb_async(function(id){}).catch(function(e){Beam.call('rec_e','err:'+e);});"}, name: "asy_e")

      Actor.io_complete(pid, 1, "boom", false)
      assert_receive {:e, "err:boom"}, 5000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks __wb_async")
    end
  end
end
