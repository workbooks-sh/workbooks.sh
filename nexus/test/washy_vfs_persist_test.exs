defmodule Nexus.WashyVfsPersistTest do
  @moduledoc """
  wb-8mdz.2 — a file written by a JS guest in one message must still be there in the next. The VFS (:map
  backend) is now threaded through the persistent %Instance{} (like the QuickJS heap), so writes survive
  across re-entries instead of being reset to {main: script} each delivery.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Actor

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

  defp vfs_wasm? do
    qjs = "compilers/js/qjs-run.wasm"

    File.exists?(qjs) and
      match?(
        {:ok, "function"},
        Nexus.Washy.Sandbox.run_command({:interp, File.read!(qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof require('fs').writeFileSync));"}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
      )
  end

  test "a file written in message 1 is readable in message 2 (VFS persists across re-entries)" do
    if vfs_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:got, v}); {:ok, nil} end, name: "vrec")

      script = """
      var fs=require('fs'); var n=0;
      Beam.onMessage(function(m){
        n++;
        if(n===1){ fs.writeFileSync('/work/x.txt','persisted-'+m.v); }
        else { Beam.call('vrec', fs.readFileSync('/work/x.txt','utf8')); }
      });
      """

      {:ok, _} = Actor.beam_spawn({:js, script}, name: "vactor")
      Actor.beam_send("vactor", %{"v" => 42})
      Actor.beam_send("vactor", %{})
      assert_receive {:got, "persisted-42"}, 8000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks fs")
    end
  end
end
