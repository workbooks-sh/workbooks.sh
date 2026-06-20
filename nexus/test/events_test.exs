defmodule Nexus.EventsTest do
  use ExUnit.Case
  alias Nexus.{Events, Effects, Hook}

  setup do
    # Fresh bus infra per run (the app tree may not be started under `mix test`).
    for {id, spec} <- [
          {Nexus.Events.Registry, {Registry, keys: :duplicate, name: Nexus.Events.Registry}},
          {Nexus.Events.TaskSup, {Task.Supervisor, name: Nexus.Events.TaskSup}}
        ] do
      case spec do
        {Registry, opts} -> (Process.whereis(id) || start_supervised!({Registry, opts}))
        {Task.Supervisor, name: n} -> (Process.whereis(n) || start_supervised!({Task.Supervisor, name: n}))
      end
    end

    Effects.install_builtins()
    :persistent_term.put({Nexus.Hook, :hooks}, %{})
    :ok
  end

  test "hook compiles to a spec with match + effects" do
    node = %{kind: "hook", name: "auto_lint", ast: quote do
      hook :auto_lint do
        match tags: [:file_edit]
        run agent: "linter"
      end
    end}

    spec = Hook.compile(node)
    assert spec.name == "auto_lint"
    assert spec.match.tags == [:file_edit]
    assert [%{name: "run", args: %{agent: "linter"}}] = spec.effects
  end

  test "matching/1 selects hooks by tag intersection" do
    Hook.compile(%{kind: "hook", name: "a", ast: quote do
      hook :a do
        match tags: [:deploy]
        notify title: "deployed"
      end
    end})

    assert [%{name: "a"}] = Hook.matching(%{tags: ["event", "deploy"]})
    assert [] = Hook.matching(%{tags: ["unrelated"]})
  end

  test "emit runs a matching hook's effect (async)" do
    me = self()
    Effects.register("test_sink", fn args, event, _ctx -> send(me, {:fired, args, event}); :ok end)

    Hook.compile(%{kind: "hook", name: "s", ast: quote do
      hook :s do
        match tags: [:ping]
        test_sink note: "hi"
      end
    end})

    Events.emit(%{kind: "ping", tags: ["ping"], title: "p"})
    assert_receive {:fired, %{note: "hi"}, %{kind: "ping"}}, 1000
  end

  test "subscribers receive broadcast events through their filter" do
    Events.subscribe(fn ev -> ev[:kind] == "watch" end)
    Events.emit(%{kind: "ignore", tags: []})
    Events.emit(%{kind: "watch", tags: []})
    assert_receive {:event, %{kind: "watch"}}, 1000
    refute_received {:event, %{kind: "ignore"}}
  end

  test "loop guard drops events past max causation depth" do
    me = self()
    Effects.register("count", fn _a, ev, _c -> send(me, {:depth, ev[:depth]}); :ok end)

    Hook.compile(%{kind: "hook", name: "loop", ast: quote do
      hook :loop do
        match tags: [:loop]
        count
        emit kind: "loop", tags: ["loop"]
      end
    end})

    Events.emit(%{kind: "loop", tags: ["loop"]})
    Process.sleep(400)
    depths = drain([])
    assert depths != []
    assert Enum.max(depths) <= 9   # @max_depth 8 + the boundary check
  end

  defp drain(acc) do
    receive do
      {:depth, d} -> drain([d | acc])
    after
      0 -> acc
    end
  end
end
