defmodule Nexus.WashyBeamE2ETest do
  @moduledoc """
  FULL-STACK `Beam.*` interop: a JavaScript guest running as QuickJS-on-Washy participates in the BEAM
  actor model end-to-end — JS→Elixir (`Beam.call`), actor identity (`Beam.self`), and Elixir→JS message
  delivery into `Beam.onMessage`. Exercises the whole bridge: JS `Beam` global → `__beam_*` C wrappers →
  wasm host imports → `lib/washy.ex` `call_host` → `Nexus.Washy.Actor`.

  Requires a `qjs-run.wasm` built WITH the `Beam` global (harness_run.c). That binary is gitignored (part
  of the separately-published compilers package), so this test SKIPS gracefully when the local wasm lacks
  `Beam` (the host-side mechanism is covered unconditionally by washy_beam_host_test + washy_actor_test).
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

  # true iff the local qjs-run.wasm carries the Beam global (i.e. was rebuilt from the updated harness).
  defp beam_wasm do
    if File.exists?(@qjs) do
      qjs = File.read!(@qjs)
      probe = "Javy.IO.writeSync(1,new TextEncoder().encode(typeof Beam));"

      case Sandbox.run_command({:interp, qjs, probe}, "", fuel: 50_000_000_000, timeout_ms: 60_000) do
        {:ok, "object"} -> qjs
        _ -> nil
      end
    end
  end

  test "a JS guest calls an Elixir handler via Beam.call and gets the reply" do
    if qjs = beam_wasm() do
      {:ok, _} = Actor.beam_spawn(fn [a, b], _ -> {a + b, nil} end, name: "adder")
      src = "var r=Beam.call('adder',3,4);Javy.IO.writeSync(1,new TextEncoder().encode('r='+r));"
      assert {:ok, "r=7"} = Sandbox.run_command({:interp, qjs, src}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the Beam global (rebuild the compilers package)")
    end
  end

  test "a JS actor's state PERSISTS across messages (persistent QuickJS instance)" do
    if _qjs = beam_wasm() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:n, v}); {:ok, nil} end, name: "rec")
      # `count` lives in the QuickJS heap; if the instance persists, three sends → 1,2,3 (not 1,1,1).
      {:ok, _} = Actor.beam_spawn({:js, "var count=0; Beam.onMessage(function(m){count++; Beam.call('rec', count);});"}, name: "ctr")

      Enum.each(1..3, fn _ -> Actor.beam_send("ctr", %{}) end)
      assert_receive {:n, 1}, 8000
      assert_receive {:n, 2}, 8000
      assert_receive {:n, 3}, 8000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the Beam global / wb_dispatch (rebuild the compilers package)")
    end
  end

  test "Elixir → JS: a Beam.send delivers into the guest's onMessage callback" do
    if _qjs = beam_wasm() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:recorded, v}); {:ok, nil} end, name: "recorder")
      {:ok, _} = Actor.beam_spawn({:js, "Beam.onMessage(function(m){Beam.call('recorder', m.x);});"}, name: "jsguest")

      Actor.beam_send("jsguest", %{"x" => 42})
      assert_receive {:recorded, 42}, 8000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the Beam global")
    end
  end
end
