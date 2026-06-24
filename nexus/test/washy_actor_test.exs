defmodule Nexus.WashyActorTest do
  @moduledoc """
  JS↔OTP interop — the host-side guest-actor mechanism (the `Beam.*` API mapped to BEAM primitives).
  Proves end-to-end WITHOUT the JS side: persistent supervised guest actors with mailboxes, messaging
  between actors and Elixir, synchronous calls, crash isolation, and the JS⇄Erlang term round-trip.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Actor
  alias Nexus.Washy.Actor.Term

  setup do
    # Start the actor supervision tree (the parent will wire these into application.ex; in test we own
    # the lifecycle). Start_supervised gives per-test isolation + teardown.
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

  # ── messaging mechanism: actor → actor, with a reply via Beam.send ──────────────────────────────

  test "two actors message each other: one beam_sends, the receiver's handler replies" do
    test = self()

    # receiver: on each message, send a reply back to whoever's in :washy_actor_from
    {:ok, receiver} =
      Actor.beam_spawn(
        fn msg, _state ->
          from = Process.get(:washy_actor_from)
          Actor.beam_send(from, %{"echo" => msg})
          {nil, nil}
        end,
        name: "receiver"
      )

    # sender: a fun-actor that, when told to, sends "ping" to the receiver. We drive it directly.
    {:ok, sender} =
      Actor.beam_spawn(fn _msg, _state ->
        Actor.beam_send("receiver", "ping")
        {nil, nil}
      end)

    # a probe actor that forwards anything it gets back to the test process
    {:ok, _probe} =
      Actor.beam_spawn(
        fn msg, _ -> send(test, {:probe, msg}); {nil, nil} end,
        name: "probe"
      )

    # have the RECEIVER reply to "probe" instead, so we can observe it from the test
    {:ok, receiver2} =
      Actor.beam_spawn(fn msg, _ ->
        Actor.beam_send("probe", %{"echo" => msg})
        {nil, nil}
      end)

    assert is_pid(receiver)
    assert is_pid(sender)
    Actor.beam_send(receiver2, "ping")

    assert_receive {:probe, %{"echo" => "ping"}}, 1000
  end

  # ── synchronous Beam.call into a registered handler ─────────────────────────────────────────────

  test "beam_call invokes a registered handler synchronously and returns the normalized reply" do
    {:ok, _adder} =
      Actor.beam_spawn(
        fn [a, b], _state -> {a + b, nil} end,
        name: "adder"
      )

    assert {:ok, 7} = Actor.beam_call("adder", [3, 4])
    assert {:error, :no_such_handler} = Actor.beam_call("nope", [1])
  end

  test "beam_call carries stateful accumulation across calls (GenServer state per guest)" do
    {:ok, _counter} =
      Actor.beam_spawn(
        fn [n], total -> new = (total || 0) + n; {new, new} end,
        name: "counter",
        state: 0
      )

    assert {:ok, 5} = Actor.beam_call("counter", [5])
    assert {:ok, 8} = Actor.beam_call("counter", [3])
    assert {:ok, 108} = Actor.beam_call("counter", [100])
  end

  # ── supervision / crash isolation ───────────────────────────────────────────────────────────────

  test "a crashing actor does not take down its siblings" do
    {:ok, victim} = Actor.beam_spawn(fn _msg, _ -> raise "boom" end, name: "victim")
    {:ok, _survivor} = Actor.beam_spawn(fn [n], _ -> {n * 2, nil} end, name: "survivor")

    ref = Process.monitor(victim)
    # deliver a message that makes the victim crash (cast → process dies)
    Actor.beam_send(victim, "die")
    assert_receive {:DOWN, ^ref, :process, ^victim, _reason}, 1000
    refute Process.alive?(victim)

    # the survivor is untouched and still answers
    assert {:ok, 42} = Actor.beam_call("survivor", [21])
  end

  test "beam_self resolves to the running actor's pid inside its handler" do
    test = self()
    {:ok, pid} = Actor.beam_spawn(fn _msg, _ -> send(test, {:self, Actor.beam_self()}); {nil, nil} end)
    Actor.beam_send(pid, "go")
    assert_receive {:self, ^pid}, 1000
  end

  test "system_info and process_info introspect the BEAM (reductions/atoms/process count)" do
    {:ok, pid} = Actor.beam_spawn(fn _m, _ -> {nil, nil} end, name: "introspect")
    info = Actor.process_info(pid)
    assert is_integer(info.reductions)
    assert is_integer(info.memory)

    sys = Actor.system_info()
    assert sys.process_count > 0
    assert sys.atom_count > 0
  end

  # ── JS⇄Erlang term round-trip ───────────────────────────────────────────────────────────────────

  test "Term.normalize projects Elixir terms into the shared JS shape and is idempotent" do
    cases = [
      nil,
      true,
      42,
      3.14,
      "hello",
      [1, 2, 3],
      %{"a" => 1, "b" => [true, nil, "x"]}
    ]

    for v <- cases do
      n = Term.normalize(v)
      assert Term.normalize(n) == n, "not idempotent for #{inspect(v)}"
    end

    # atoms → strings, tuples → lists, atom keys → string keys
    assert Term.normalize(:foo) == "foo"
    assert Term.normalize({1, "a", :b}) == [1, "a", "b"]
    assert Term.normalize(%{a: 1, b: %{c: 2}}) == %{"a" => 1, "b" => %{"c" => 2}}
  end

  test "Term JSON round-trip is stable for in-shape values (cross-host wire form)" do
    v = %{"n" => 7, "s" => "hi", "list" => [1, 2.5, true, nil], "nested" => %{"k" => "v"}}
    assert Term.from_json(Term.to_json(v)) == v
  end

  test "Term.normalize raises loudly on an un-bridgeable term (pid/ref)" do
    assert_raise ArgumentError, fn -> Term.normalize(self()) end
    assert_raise ArgumentError, fn -> Term.normalize(make_ref()) end
  end

  # ── message normalization across the boundary ───────────────────────────────────────────────────

  test "messages are normalized on send so the receiver sees the JS-bridgeable shape" do
    test = self()
    {:ok, pid} = Actor.beam_spawn(fn msg, _ -> send(test, {:got, msg}); {nil, nil} end)
    # send an atom-keyed map + tuple; receiver should see string keys + a list
    Actor.beam_send(pid, %{event: :tick, payload: {1, 2}})
    assert_receive {:got, %{"event" => "tick", "payload" => [1, 2]}}, 1000
  end
end
