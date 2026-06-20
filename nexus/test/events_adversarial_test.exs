defmodule Nexus.EventsAdversarialTest do
  use ExUnit.Case
  alias Nexus.{Events, Effects, Hook}

  setup do
    for {id, spec} <- [
          {Nexus.Events.Registry, {Registry, keys: :duplicate, name: Nexus.Events.Registry}},
          {Nexus.Events.TaskSup, {Task.Supervisor, name: Nexus.Events.TaskSup}}
        ] do
      case spec do
        {Registry, opts} -> Process.whereis(id) || start_supervised!({Registry, opts})
        {Task.Supervisor, name: n} -> Process.whereis(n) || start_supervised!({Task.Supervisor, name: n})
      end
    end

    Effects.install_builtins()
    :persistent_term.put({Nexus.Hook, :hooks}, %{})
    :ok
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, v} -> drain(tag, [v | acc])
    after
      0 -> acc
    end
  end

  # ── 1. Loop guard correctness ───────────────────────────────────────────────

  test "P1a: self-emitting hook terminates at depth cap (no runaway)" do
    me = self()
    Effects.register("count1", fn _a, ev, _c -> send(me, {:c1, ev[:depth]}); :ok end)

    Hook.compile(%{kind: "hook", name: "loop1", ast: quote do
      hook :loop1 do
        match tags: [:loop1]
        count1
        emit kind: "loop1", tags: ["loop1"]
      end
    end})

    Events.emit(%{kind: "loop1", tags: ["loop1"]})
    Process.sleep(500)
    depths = drain(:c1)
    # depths 0..8 inclusive => 9 runs. depth 9 emit is dropped.
    assert Enum.max(depths) <= 8, "ran past cap, depths=#{inspect(Enum.sort(depths))}"
    assert length(depths) <= 12, "runaway: #{length(depths)} runs"
    assert length(depths) >= 8
  end

  test "P1b: two mutually-triggering hooks stay bounded" do
    me = self()
    Effects.register("ca", fn _a, ev, _c -> send(me, {:ca, ev[:depth]}); :ok end)
    Effects.register("cb", fn _a, ev, _c -> send(me, {:cb, ev[:depth]}); :ok end)

    Hook.compile(%{kind: "hook", name: "A", ast: quote do
      hook :A do
        match tags: [:ta]
        ca
        emit kind: "b", tags: ["tb"]
      end
    end})
    Hook.compile(%{kind: "hook", name: "B", ast: quote do
      hook :B do
        match tags: [:tb]
        cb
        emit kind: "a", tags: ["ta"]
      end
    end})

    Events.emit(%{kind: "a", tags: ["ta"]})
    Process.sleep(600)
    total = length(drain(:ca)) + length(drain(:cb))
    # bounded: each level increments depth, capped at 8.
    assert total <= 20, "mutual loop not bounded: #{total} runs"
    assert total >= 8
  end

  # ── 2. Effect crash isolation ───────────────────────────────────────────────

  test "P2: a crashing effect doesn't stop sibling effects or the bus" do
    me = self()
    Effects.register("boom", fn _a, _e, _c -> raise "kaboom" end)
    Effects.register("sibling", fn _a, _e, _c -> send(me, :sibling_ran); :ok end)

    Hook.compile(%{kind: "hook", name: "x", ast: quote do
      hook :x do
        match tags: [:x]
        boom
        sibling
      end
    end})

    pre = Process.whereis(Nexus.Events.TaskSup)
    Events.emit(%{kind: "x", tags: ["x"]})
    assert_receive :sibling_ran, 1000
    # emitter & supervisor survive
    assert Process.whereis(Nexus.Events.TaskSup) == pre
    # bus still works afterwards
    Effects.register("again", fn _a, _e, _c -> send(me, :again); :ok end)
    Hook.compile(%{kind: "hook", name: "y", ast: quote do
      hook :y do
        match tags: [:y]
        again
      end
    end})
    Events.emit(%{kind: "y", tags: ["y"]})
    assert_receive :again, 1000
  end

  test "P2b: effect that exits (not raise) is isolated by supervisor" do
    me = self()
    Effects.register("exiter", fn _a, _e, _c -> exit(:bad) end)
    Effects.register("after_exit", fn _a, _e, _c -> send(me, :after_exit); :ok end)

    Hook.compile(%{kind: "hook", name: "z", ast: quote do
      hook :z do
        match tags: [:z]
        exiter
        after_exit
      end
    end})

    Events.emit(%{kind: "z", tags: ["z"]})
    assert_receive :after_exit, 1000
    assert Process.alive?(self())
  end

  # ── 3. Subscriber filter robustness ─────────────────────────────────────────

  test "P3a: a raising filter doesn't break delivery to others" do
    Events.subscribe(fn _ev -> raise "filter boom" end)
    Events.subscribe(fn ev -> ev[:kind] == "ok" end)
    Events.emit(%{kind: "ok", tags: []})
    assert_receive {:event, %{kind: "ok"}}, 1000
  end

  test "P3b: dead subscriber doesn't break dispatch" do
    {pid, ref} = spawn_monitor(fn ->
      Events.subscribe(fn _ -> true end)
      receive do: (:go -> :ok)
    end)
    # let it register
    Process.sleep(50)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    # now emit; Registry auto-deregisters dead pids, should not crash
    Events.subscribe(fn _ -> true end)
    Events.emit(%{kind: "post", tags: []})
    assert_receive {:event, %{kind: "post"}}, 1000
  end

  test "P3c: 100 selective subscribers each get only their match" do
    parent = self()
    pids = for i <- 1..100 do
      spawn(fn ->
        Events.subscribe(fn ev -> ev[:n] == rem(i, 10) end)
        send(parent, {:ready, i})
        receive do
          {:event, ev} -> send(parent, {:got, ev[:n]})
        after
          2000 -> :ok
        end
      end)
    end
    for _ <- 1..100, do: assert_receive({:ready, _}, 2000)
    Events.emit(%{kind: "fan", tags: [], n: 3})
    Process.sleep(300)
    got = drain(:got)
    # only subscribers with rem(i,10)==3 (i=3,13,...,93) => 10 of them
    assert length(got) == 10, "expected 10 matches got #{length(got)}: #{inspect(got)}"
    assert Enum.all?(got, fn n -> n == 3 end)
    _ = pids
  end

  # ── 4. Match semantics edge cases ───────────────────────────────────────────

  test "P4a: empty-match hook matches everything but only fires its own effects" do
    me = self()
    Effects.register("anyhook", fn _a, ev, _c -> send(me, {:any, ev[:kind]}); :ok end)
    Hook.compile(%{kind: "hook", name: "catchall", ast: quote do
      hook :catchall do
        anyhook
      end
    end})
    Events.emit(%{kind: "whatever", tags: []})
    Events.emit(%{kind: "other", tags: ["zzz"]})
    Process.sleep(200)
    kinds = drain(:any) |> Enum.sort()
    assert kinds == ["other", "whatever"]
  end

  test "P4b: atom tags on event match string tags in hook" do
    assert Hook.matches?(%{tags: [:deploy]}, %{tags: [:deploy]})
    assert Hook.matches?(%{tags: ["deploy"]}, %{tags: [:deploy]})
    assert Hook.matches?(%{tags: [:deploy]}, %{tags: ["deploy"]})
  end

  test "P4c: empty-match always true; absent kind/tags handled" do
    assert Hook.matches?(%{}, %{})
    assert Hook.matches?(%{}, %{kind: "k"})
    # empty match true even with tags: nil because no tags/kind clause is consulted
    assert Hook.matches?(%{}, %{kind: nil, tags: nil})
    refute Hook.matches?(%{kind: ["deploy"]}, %{kind: nil})
    refute Hook.matches?(%{tags: [:x]}, %{})
  end

  test "P4d: tags AND kind must BOTH match" do
    m = %{tags: [:deploy], kind: ["release"]}
    refute Hook.matches?(m, %{tags: ["deploy"], kind: "other"})
    refute Hook.matches?(m, %{tags: ["nope"], kind: "release"})
    assert Hook.matches?(m, %{tags: ["deploy", "x"], kind: "release"})
  end

  test "P4e2: FIXED — emit of an event with tags: nil does NOT crash the emitter" do
    # Regression for the nil-tags bug: a tag-filtered hook is registered, then an event with
    # tags: nil is emitted. matching/1 now coalesces nil, and dispatch_hooks wraps matching in a
    # rescue, so emit/2 returns normally for the caller (no propagated crash).
    Hook.compile(%{kind: "hook", name: "tagged", ast: quote do
      hook :tagged do
        match tags: [:something]
        notify title: "x"
      end
    end})
    ev = Nexus.Events.emit(%{kind: "k", tags: nil})
    assert ev.kind == "k"
  end

  test "P4e: FIXED — event with explicit nil :tags is handled (no match, no crash)" do
    # `tags: nil` (key present, value nil) is now coalesced to [] in tags_ok?, so a tag-filtered
    # hook simply doesn't match (rather than raising Protocol.UndefinedError).
    refute Hook.matches?(%{tags: [:a]}, %{tags: nil})
    # Likewise kind: explicit nil is handled (kind_ok? compares to_string(nil)="" ) — OK.
    refute Hook.matches?(%{kind: ["x"]}, %{kind: nil})
  end

  # ── 5. Hook compile robustness ──────────────────────────────────────────────

  test "P5a: hook with no match (empty) compiles, matches all" do
    spec = Hook.compile(%{kind: "hook", name: "nomatch", ast: quote do
      hook :nomatch do
        notify title: "hi"
      end
    end})
    assert spec.match == %{}
    assert Hook.matches?(spec.match, %{kind: "anything"})
  end

  test "P5b: hook with no effects compiles to empty effects" do
    spec = Hook.compile(%{kind: "hook", name: "noeff", ast: quote do
      hook :noeff do
        match tags: [:a]
      end
    end})
    assert spec.effects == []
  end

  test "P5c: single-statement body (no __block__) compiles" do
    spec = Hook.compile(%{kind: "hook", name: "single", ast: quote do
      hook :single do
        notify title: "solo"
      end
    end})
    assert [%{name: "notify"}] = spec.effects
  end

  test "P5d: duplicate name re-register replaces, not duplicates" do
    Hook.compile(%{kind: "hook", name: "dup", ast: quote do
      hook :dup do
        match tags: [:v1]
        notify title: "one"
      end
    end})
    Hook.compile(%{kind: "hook", name: "dup", ast: quote do
      hook :dup do
        match tags: [:v2]
        notify title: "two"
      end
    end})
    dups = Enum.filter(Hook.all(), &(&1.name == "dup"))
    assert length(dups) == 1
    assert hd(dups).match.tags == [:v2]
  end

  test "P5e: match with non-keyword args" do
    # match called with a bare value instead of keywords
    result = try do
      Hook.compile(%{kind: "hook", name: "badmatch", ast: quote do
        hook :badmatch do
          match :weird
          notify title: "x"
        end
      end})
      :ok
    rescue
      e -> {:raised, e}
    end
    assert result == :ok, "compile crashed on non-keyword match: #{inspect(result)}"
  end

  test "P5f: match with mixed keyword + bare element (Enum.into target)" do
    result = try do
      Hook.compile(%{kind: "hook", name: "mixmatch", ast: quote do
        hook :mixmatch do
          match [tags: [:a]]
          notify title: "x"
        end
      end})
      :ok
    rescue
      e -> {:raised, e}
    end
    assert result == :ok, "compile crashed: #{inspect(result)}"
  end

  test "P5g: compile of non-hook node returns nil, doesn't crash" do
    assert Hook.compile(%{kind: "data", name: "foo"}) == nil
    assert Hook.compile(:garbage) == nil
  end

  test "P5h: hook node with nil ast doesn't crash" do
    result = try do
      Hook.compile(%{kind: "hook", name: "nilast", ast: nil})
    rescue
      e -> {:raised, e}
    end
    assert match?(%{name: "nilast"}, result), "got #{inspect(result)}"
  end

  test "P5i: effect call with weird positional args" do
    spec = Hook.compile(%{kind: "hook", name: "weirdargs", ast: quote do
      hook :weirdargs do
        match tags: [:w]
        notify "just a string"
      end
    end})
    assert [%{name: "notify", args: %{value: "just a string"}}] = spec.effects
  end

  # ── 6. Concurrency / fan-out ────────────────────────────────────────────────

  test "P6: 1000 concurrent emits across processes, several hooks, no losses" do
    me = self()
    Effects.register("tally", fn _a, _e, _c -> send(me, {:tally, 1}); :ok end)
    for n <- 1..3 do
      Hook.compile(%{kind: "hook", name: "h#{n}", ast: quote do
        hook :"h#{unquote(n)}" do
          match tags: [:fan]
          tally
        end
      end})
    end

    tasks = for _ <- 1..1000 do
      Task.async(fn -> Events.emit(%{kind: "fan", tags: ["fan"]}) end)
    end
    Enum.each(tasks, &Task.await(&1, 5000))
    Process.sleep(1500)
    count = length(drain(:tally))
    # 1000 emits * 3 hooks = 3000 tally runs
    assert count == 3000, "lost dispatches: got #{count}/3000"
  end

  # ── 7. Builtins ─────────────────────────────────────────────────────────────

  test "P7a: run with valid mfa applies it" do
    handler = Effects.handlers()["run"]
    assert handler.(%{mfa: {Kernel, :+, [40, 2]}}, %{}, %{}) == 42
  end

  test "P7b: run with invalid module returns error tuple or raises (documented)" do
    handler = Effects.handlers()["run"]
    result = try do
      handler.(%{mfa: {NoSuchModule, :nope, []}}, %{}, %{})
    rescue
      e -> {:raised, e}
    end
    # apply on missing module raises UndefinedFunctionError — caught by bus try/rescue at dispatch.
    assert match?({:raised, _}, result) or match?({:error, _}, result),
           "got #{inspect(result)}"
  end

  test "P7c: run with neither agent nor mfa returns error" do
    handler = Effects.handlers()["run"]
    assert handler.(%{}, %{}, %{}) == {:error, :run_needs_agent_or_mfa}
  end

  test "P7d: notify with and without title returns :ok" do
    handler = Effects.handlers()["notify"]
    assert handler.(%{title: "t"}, %{}, %{}) == :ok
    assert handler.(%{}, %{kind: "k"}, %{}) == :ok
    assert handler.(%{}, %{}, %{}) == :ok
  end

  test "P7e: unknown effect returns error, never raises" do
    assert Effects.run(%{name: "nonexistent", args: %{}}, %{}, %{}) == {:error, :unknown_effect}
  end

  test "P7f: emit builtin increments depth and chains" do
    me = self()
    Effects.register("chained", fn _a, ev, _c -> send(me, {:chained, ev[:depth]}); :ok end)
    Hook.compile(%{kind: "hook", name: "chain", ast: quote do
      hook :chain do
        match tags: [:chain]
        chained
      end
    end})
    handler = Effects.handlers()["emit"]
    handler.(%{kind: "c", tags: ["chain"]}, %{}, %{depth: 0})
    assert_receive {:chained, 1}, 1000
  end
end
