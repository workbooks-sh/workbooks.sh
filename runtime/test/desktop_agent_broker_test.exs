defmodule Workbooks.DesktopAgentBrokerTest do
  @moduledoc """
  Hermetic tests for the desktop ACP broker (`Workbooks.DesktopAgent`) — NO real claude/codex,
  no network, no LLM. The happy path drives a FAKE ACP agent: a tiny stdio script
  (test/fixtures/fake_acp_agent.exs, wrapped by a generated absolute-path launcher) that speaks
  the minimal Agent Client Protocol the broker needs (initialize → session/new → session/prompt
  with streamed session/update notifications).

  Coverage (the load-bearing safety properties + one real turn):

    1. WB_DESKTOP-gating: in a simulated cloud/multi-tenant posture the broker REFUSES — no spawn,
       no route. `Gate.enabled?` is false and every public entry fail-closes `:acp_desktop_only`.
    2. Only enabled when WB_DESKTOP (or WB_ACP_DESKTOP) AND NOT Tenancy.multi?.
    3. An un-allowlisted agent binary/id is refused (`:unknown_agent`).
    4. Happy path: a full ACP turn against the fake agent returns the structured result AND emits
       telemetry DAG events (the `_steps.jsonl` records the Workflow.Telemetry DAG ingests).
    5. The guest/sandbox cannot reach it: it is NOT a guest tool, NOT a Dock import, NOT a cloud
       route — by source-grep, the only references are the broker file + the gated supervision wire.

  `async: false` — these mutate process env (posture) and a shared DynamicSupervisor.
  """
  use ExUnit.Case, async: false

  alias Workbooks.DesktopAgent
  alias Workbooks.DesktopAgent.Gate

  @sup Workbooks.DesktopAgent.Sup

  # Save/restore every env var the gate + tenancy posture read.
  @posture_env ~w(WB_DESKTOP WB_ACP_DESKTOP WB_TENANCY_MODE WB_CONTROL_PLANE WB_CLOUD FLY_APP_NAME)

  setup do
    saved = for k <- @posture_env, do: {k, System.get_env(k)}
    for {k, _} <- saved, do: System.delete_env(k)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      stop_sup()
    end)

    :ok
  end

  # Bring the leg-1 supervisor up by hand (the app's child_specs/0 only runs it at boot). Mirrors
  # exactly what Workbooks.Application does: start it iff Gate.enabled?.
  defp start_sup do
    stop_sup()
    for spec <- DesktopAgent.child_specs(), do: start_supervised!(spec)
    :ok
  end

  defp stop_sup do
    case Process.whereis(@sup) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: Supervisor.stop(pid, :normal), else: :ok
    end
  rescue
    _ -> :ok
  end

  defp desktop_posture, do: System.put_env("WB_DESKTOP", "1")

  # ── (1)+(2) WB_DESKTOP / multi-tenant gating ─────────────────────────────────

  describe "posture gate (legs 1 + 2)" do
    test "no WB_DESKTOP: gate off, no supervisor, every entry fail-closes :acp_desktop_only" do
      refute Gate.enabled?()
      # leg 1: the supervision child-spec is empty — the DynamicSupervisor is never started.
      assert DesktopAgent.child_specs() == []
      start_sup()
      refute Process.whereis(@sup)

      # leg 2: the function boundary refuses regardless.
      assert DesktopAgent.agents() == []
      assert DesktopAgent.spawn("claude", "do a thing", workdir: tmp_workdir()) ==
               {:error, :acp_desktop_only}
    end

    test "WB_DESKTOP=1 but multi-tenant (cloud posture): gate OFF — multi overrides" do
      desktop_posture()
      System.put_env("WB_TENANCY_MODE", "multi")
      System.put_env("FLY_APP_NAME", "wb-prod")

      assert Workbooks.Tenancy.multi?()
      refute Gate.enabled?()
      assert DesktopAgent.child_specs() == []
      assert DesktopAgent.agents() == []
      assert DesktopAgent.spawn("claude", "x", workdir: tmp_workdir()) ==
               {:error, :acp_desktop_only}
    end

    test "WB_ACP_DESKTOP=1 single-tenant: gate ON, supervisor present, agents listed" do
      System.put_env("WB_ACP_DESKTOP", "1")
      refute Workbooks.Tenancy.multi?()
      assert Gate.enabled?()
      assert DesktopAgent.child_specs() != []
      start_sup()
      assert Process.whereis(@sup)
      assert DesktopAgent.agents() == ["claude", "codex"]
    end
  end

  # ── (3) allowlist ────────────────────────────────────────────────────────────

  test "un-allowlisted agent id is refused (:unknown_agent), gate ON" do
    desktop_posture()
    start_sup()
    assert Gate.enabled?()
    assert DesktopAgent.spawn("rogue-binary", "x", workdir: tmp_workdir()) ==
             {:error, :unknown_agent}
    # absolute non-claude path can't sneak in through a logical id either.
    assert DesktopAgent.spawn("/usr/bin/evil", "x", workdir: tmp_workdir()) ==
             {:error, :unknown_agent}
  end

  test "an allowlisted id with a non-existent absolute binary is :agent_not_installed (not posture)" do
    desktop_posture()
    start_sup()
    assert DesktopAgent.spawn("claude", "x",
             bin: "/nonexistent/abs/claude",
             workdir: tmp_workdir()
           ) == {:error, :agent_not_installed}
  end

  # ── (4) happy path: a full ACP turn against the FAKE agent + telemetry DAG ────

  test "happy path — full ACP turn returns structured result + emits telemetry DAG events" do
    desktop_posture()
    start_sup()

    workdir = tmp_workdir()
    bin = fake_agent_launcher()

    assert {:ok, pid} = DesktopAgent.spawn("claude", "hello world", bin: bin, workdir: workdir)
    assert is_pid(pid)

    assert {:ok, result} = DesktopAgent.await(pid, 30_000)

    # structured result shape
    assert result.stop_reason == "end_turn"
    assert result.output == "echo:hello world"
    assert is_list(result.artifacts)
    assert result.usage[:used] == 42

    # telemetry DAG: the broker appends the standard step shape to <workdir>/_steps.jsonl — the
    # exact records Workflow.Telemetry ingests into step_events. The tool_call/tool_call_update
    # pair must have produced one closed step.
    steps_path = Path.join(workdir, "_steps.jsonl")
    assert File.exists?(steps_path), "broker must emit the telemetry _steps.jsonl"

    steps =
      steps_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [step] = steps
    assert step["agent"] == "claude"
    assert step["tool"] == "read"
    assert step["exit_code"] == 0
    assert step["error"] == nil
    assert is_integer(step["step"])
    assert is_integer(step["ts"])

    # And the broker's records are exactly what the shared Telemetry DAG ingests.
    run_id = "delegated-run"
    assert Workbooks.Workflow.Telemetry.persist(workdir, run_id, []) == :ok
  end

  # ── (5) guest unreachable — NOT a guest tool / NOT a cloud route ─────────────

  test "broker is not a guest tool, not a Dock import, not a loopback/cloud route" do
    # The capability has no NAME the in-wasm guest can reach. Defense by construction: assert
    # the ONLY source references to DesktopAgent are the broker file itself and the gated
    # supervision wire in application.ex — no agent-loop tool, no Dock import, no route.
    host = Path.expand(Path.join(__DIR__, "../host"))

    refs =
      Path.wildcard(Path.join(host, "**/*.ex"))
      |> Enum.filter(fn f -> File.read!(f) =~ "DesktopAgent" end)
      |> Enum.map(&Path.relative_to(&1, host))
      |> Enum.sort()

    assert refs == ["application.ex", "desktop_agent.ex"],
           "DesktopAgent leaked into #{inspect(refs -- ["application.ex", "desktop_agent.ex"])} — " <>
             "the broker must NOT be wired into the agent loop, a Dock import, or a route."

    # The single application.ex reference is the GATED supervision wire (child_specs/0), not a
    # route or an unconditional start.
    app = File.read!(Path.join(host, "application.ex"))
    assert app =~ "Workbooks.DesktopAgent.child_specs()"

    # No guest-facing surface (Dock import / agent tool / loopback route) names it.
    refute app =~ ~r/route.*DesktopAgent/i

    for f <- ~w(instance/imports.ex agent.ex) do
      p = Path.join(host, f)
      if File.exists?(p), do: refute(File.read!(p) =~ "DesktopAgent")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp tmp_workdir do
    dir = Path.join(System.tmp_dir!(), "wb-desktop-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Generate an absolute-path executable launcher that execs the fake ACP agent under `elixir`.
  # The broker requires an ABSOLUTE :bin that File.exists? — a wrapper script is the user's "own
  # binary" stand-in. It ignores the broker-supplied "--acp" argv (the fake agent needs no flags).
  defp fake_agent_launcher do
    script = Path.expand(Path.join(__DIR__, "fixtures/fake_acp_agent.exs"))
    elixir = System.find_executable("elixir") || raise "elixir not on PATH for the test launcher"

    launcher = Path.join(System.tmp_dir!(), "fake-claude-#{System.unique_integer([:positive])}")

    File.write!(launcher, """
    #!/bin/sh
    exec #{elixir} #{script}
    """)

    File.chmod!(launcher, 0o755)
    on_exit(fn -> File.rm(launcher) end)
    launcher
  end
end
