defmodule Nexus.WorkerTest do
  @moduledoc "The `worker` kind — a long-lived, supervised, stateful background process (the GenServer concept in `.work`)."
  use ExUnit.Case, async: false

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  # a counter worker: init seeds 0, each tick increments. `every:` in ms (integer) for fast tests.
  defp counter(name, every),
    do: unit("worker :#{name}, every: #{every} do\n  def init, do: 0\n  def tick(n), do: n + 1\nend\n")

  test "a `worker` parses as a code unit of kind=worker" do
    n = counter("w_parse", 1000)
    assert n.kind == "worker"
    assert n.name == "w_parse"
  end

  test "compile builds a spec (module + interval + restart) but does NOT start a process" do
    spec = Nexus.Worker.compile(counter("w_compile", 30))
    assert spec.name == "w_compile"
    assert spec.interval_ms == 30
    assert spec.restart == :permanent          # daemon default
    assert function_exported?(spec.module, :init, 0)
    refute "w_compile" in Nexus.Worker.running()
  end

  test "starting a worker runs init, then ticks on its interval — supervised + introspectable" do
    spec = Nexus.Worker.compile(counter("w_run", 25))
    assert {:ok, pid} = Nexus.Worker.start(spec)
    assert is_pid(pid)
    assert "w_run" in Nexus.Worker.running()

    # init just ran → state is its seed (0); after several intervals it has ticked forward
    assert Nexus.Worker.state("w_run") in 0..2
    Process.sleep(140)
    assert Nexus.Worker.state("w_run") >= 3

    assert :ok = Nexus.Worker.stop("w_run")
    refute "w_run" in Nexus.Worker.running()
  end

  test "the `restart:` policy is honored from the declaration" do
    spec =
      Nexus.Worker.compile(
        unit("worker :w_restart, every: 1000, restart: :transient do\n  def init, do: :ok\nend\n")
      )

    assert spec.restart == :transient
  end

  test "a killed worker is restarted by the supervisor (it's permanent)" do
    spec = Nexus.Worker.compile(counter("w_kill", 1000))
    {:ok, pid1} = Nexus.Worker.start(spec)

    Process.exit(pid1, :kill)
    Process.sleep(80)

    pid2 = Nexus.Worker.pid("w_kill")
    assert is_pid(pid2) and pid2 != pid1     # OTP brought it back under a new pid
    assert "w_kill" in Nexus.Worker.running()

    Nexus.Worker.stop("w_kill")
  end

  test "a tick that raises keeps the daemon alive on its prior state (no crash-loop)" do
    spec =
      Nexus.Worker.compile(
        unit("worker :w_bad, every: 20 do\n  def init, do: 7\n  def tick(_), do: raise(\"boom\")\nend\n")
      )

    {:ok, pid} = Nexus.Worker.start(spec)
    Process.sleep(120)

    # the process is the SAME (not restarted) and its state is untouched — a bad poll didn't tear it down
    assert Nexus.Worker.pid("w_bad") == pid
    assert Nexus.Worker.state("w_bad") == 7

    Nexus.Worker.stop("w_bad")
  end

  test "starting the same worker name again replaces the running one (remount-safe)" do
    {:ok, pid1} = Nexus.Worker.start(Nexus.Worker.compile(counter("w_dup", 1000)))
    {:ok, pid2} = Nexus.Worker.start(Nexus.Worker.compile(counter("w_dup", 1000)))

    assert pid1 != pid2
    refute Process.alive?(pid1)
    assert Nexus.Worker.pid("w_dup") == pid2

    Nexus.Worker.stop("w_dup")
  end
end
