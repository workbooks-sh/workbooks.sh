defmodule Nexus.WashyTimersTest do
  @moduledoc """
  The async spine (wb-5q8w), timer source: a JS guest's setTimeout/setInterval arm a BEAM timer via the
  __host_timer_set host import; when it fires, the owning Actor re-enters the live QuickJS instance at the
  wb_timer export, runs the JS callback run-to-completion, and drains promise microtasks. This is THE
  async-completion contract every I/O module (fs/net/http) will reuse — proven here with the simplest
  host op (a timer): host op completes → message to the actor mailbox → re-enter guest → run JS callback.

  Skips when the local qjs-run.wasm predates the timer harness (gitignored; rebuild the compilers package).
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

  # true iff the local qjs-run.wasm carries the timer globals (i.e. was rebuilt from the updated harness).
  defp timers_wasm? do
    File.exists?(@qjs) and
      match?(
        {:ok, "function"},
        Sandbox.run_command(
          {:interp, File.read!(@qjs), "Javy.IO.writeSync(1,new TextEncoder().encode(typeof setTimeout));"},
          "",
          fuel: 50_000_000_000,
          timeout_ms: 60_000
        )
      )
  end

  test "setTimeout fires its callback via mailbox re-entry" do
    if timers_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:t, v}); {:ok, nil} end, name: "rec_t")
      # armed at boot; fires ~30ms later via a BEAM timer → wb_timer re-entry → Beam.call
      {:ok, _} = Actor.beam_spawn({:js, "setTimeout(function(){Beam.call('rec_t',99);},30);"}, name: "tmr1")
      assert_receive {:t, 99}, 5000
    else
      IO.puts("\n[skip] qjs-run.wasm lacks setTimeout (rebuild the compilers package)")
    end
  end

  test "setInterval fires repeatedly and clearInterval stops it" do
    if timers_wasm?() do
      test = self()
      {:ok, _} = Actor.beam_spawn(fn [v], _ -> send(test, {:n, v}); {:ok, nil} end, name: "rec_iv")

      {:ok, _} =
        Actor.beam_spawn(
          {:js, "var n=0;var iv=setInterval(function(){n++;Beam.call('rec_iv',n);if(n>=3)clearInterval(iv);},20);"},
          name: "ivl"
        )

      assert_receive {:n, 1}, 5000
      assert_receive {:n, 2}, 5000
      assert_receive {:n, 3}, 5000
      # cleared after 3 — a 4th must NOT arrive
      refute_receive {:n, 4}, 300
    else
      IO.puts("\n[skip] qjs-run.wasm lacks setInterval")
    end
  end
end
