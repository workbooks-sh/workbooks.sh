defmodule Workbooks.Keeper.CrewTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The bit.ml CREW runtime (wb-wc0.2). Hermetic — no LLM is ever called. Covers:

    1. CREW MANIFEST parse (names, :DEF:, :LIFECYCLE:, :INTERVAL:; member without
       :DEF: dropped).
    2. Two keeper WORKERS tick INDEPENDENTLY with NAMESPACED persistence — each
       writes its own `keeper-last-run-<name>` + its own `:status` persistent_term
       key, never colliding. (Uses a missing def so the run path bounces through
       the crash-safe branch — no LLM, like keeper_test.)
    3. The lifecycle namespace is per-agent: two contexts advance independently.
    4. The concurrency GATE caps concurrent acquires and queues the rest (FIFO).
    5. The legacy SINGLETON keeper path is untouched (status namespace "").

  The /_activity crew SHAPE is covered in public_web_activity_test.exs.
  """

  alias Workbooks.Keeper.{Crew, Worker, Lifecycle}

  @manifest """
  #+TITLE: crew
  * wren
  :PROPERTIES:
  :DEF: /data/agents/writer.org
  :LIFECYCLE: /data/lifecycles/writer.org
  :INTERVAL: 10m
  :END:
  * moss
  :PROPERTIES:
  :DEF: /data/agents/editor.org
  :END:
  * ghost
  :PROPERTIES:
  :INTERVAL: 5m
  :END:
  """

  describe "manifest parse" do
    test "reads agent names, def, lifecycle, interval; drops members without :DEF:" do
      members = Crew.parse(@manifest)

      # ghost has no :DEF: → dropped; wren + moss survive in order.
      assert Enum.map(members, & &1.name) == ["wren", "moss"]

      wren = Enum.at(members, 0)
      assert wren.def_path == "/data/agents/writer.org"
      assert wren.lifecycle == "/data/lifecycles/writer.org"
      assert wren.interval_ms == 10 * 60_000

      moss = Enum.at(members, 1)
      assert moss.def_path == "/data/agents/editor.org"
      # absent :LIFECYCLE: → nil (interval ticks); absent :INTERVAL: → 1h default.
      assert moss.lifecycle == nil
      assert moss.interval_ms == 3_600_000
    end

    test "empty / heading-less manifest → []" do
      assert Crew.parse("just prose") == []
      assert Crew.parse("") == []
    end
  end

  describe "two workers tick independently with namespaced persistence" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "wb_crew_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      prev = System.get_env("WB_DATA")
      System.put_env("WB_DATA", tmp)

      on_exit(fn ->
        File.rm_rf(tmp)
        if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      end)

      %{tmp: tmp}
    end

    test "each worker writes its own keeper-last-run-<name> + own status key", %{tmp: tmp} do
      # A missing def → the wake path raises in the run Task and is absorbed by the
      # crash-safe branch (exactly like keeper_test). No LLM is reached. We assert
      # the per-agent SIDE EFFECTS: namespaced last-run files + status keys.
      cfgs =
        for name <- ["wren", "moss"] do
          %Worker.Cfg{
            name: :"crew_test_#{name}",
            agent: name,
            def_path: Path.join(tmp, "missing_#{name}.org"),
            lifecycle_ctx: nil,
            key_suffix: "-#{name}",
            interval_ms: 3_600_000,
            acquire: nil,
            release: nil
          }
        end

      pids =
        for cfg <- cfgs do
          {:ok, pid} = Worker.start_link(cfg)
          send(pid, :tick)
          {cfg, pid}
        end

      Process.sleep(200)

      for {cfg, pid} <- pids do
        assert Process.alive?(pid), "#{cfg.agent} worker must survive a missing-def tick"
        # Namespaced cadence file written for THIS agent only.
        assert File.exists?(Path.join(tmp, "keeper-last-run#{cfg.key_suffix}"))
        # Namespaced status persistent_term — running flipped back to false, agent tagged.
        status = Worker.status(cfg.key_suffix, nil)
        assert status[:active] == true
        assert status[:agent] == cfg.agent
        assert status[:running] == false
      end

      # The two namespaces are distinct files (no collision with the singleton).
      assert File.exists?(Path.join(tmp, "keeper-last-run-wren"))
      assert File.exists?(Path.join(tmp, "keeper-last-run-moss"))
      refute File.exists?(Path.join(tmp, "keeper-last-run"))

      for {_, pid} <- pids, do: GenServer.stop(pid)
    end
  end

  describe "per-agent lifecycle namespace" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "wb_crewlc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      spec = Path.join(tmp, "lc.org")
      File.write!(spec, "#+START: a\n* a\n:PROPERTIES:\n:KIND: wake\n:REPEAT: 3\n:NEXT: b\n:END:\n* b\n:PROPERTIES:\n:KIND: wake\n:NEXT: a\n:END:\n")
      prev = System.get_env("WB_DATA")
      System.put_env("WB_DATA", tmp)

      on_exit(fn ->
        File.rm_rf(tmp)
        if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
      end)

      %{spec: spec}
    end

    test "two agents advance their own lifecycle position without interfering", %{spec: spec} do
      wren = Lifecycle.ctx(def_path: spec, ns: "wren")
      moss = Lifecycle.ctx(def_path: spec, ns: "moss")

      assert Lifecycle.current(wren).state == "a"
      assert Lifecycle.current(moss).state == "a"

      # Advance wren twice; moss stays put.
      Lifecycle.advance(:done, wren)
      Lifecycle.advance(:done, wren)
      assert Lifecycle.current(wren).hits == 2
      assert Lifecycle.current(moss).hits == 0

      # Namespaced position files are distinct.
      assert File.exists?(Path.join(System.get_env("WB_DATA"), "lifecycle-pos-wren"))
      refute File.exists?(Path.join(System.get_env("WB_DATA"), "lifecycle-pos-moss"))
    end
  end

  describe "concurrency gate" do
    test "caps concurrent acquires; queued caller proceeds on release" do
      {:ok, gate} = Crew.Gate.start_link(max: 1)
      on_exit(fn -> if Process.alive?(gate), do: GenServer.stop(gate) end)

      # First acquire succeeds immediately.
      assert :ok = Crew.Gate.acquire()

      # Second acquire must BLOCK (no slot). Run it in a task and confirm it does
      # not return until we release.
      parent = self()
      t = Task.async(fn -> Crew.Gate.acquire(); send(parent, :got_slot); :ok end)
      refute_receive :got_slot, 100

      # Releasing the first slot hands it to the queued caller (FIFO).
      Crew.Gate.release()
      assert_receive :got_slot, 500
      Task.await(t)
    end
  end

  describe "singleton path untouched" do
    test "the singleton status namespace stays unsuffixed" do
      # Worker.status("") reads {Workbooks.Keeper, :status} — the legacy key the
      # lander + /_changes already poll. A crew suffix uses a 3-tuple key instead.
      # Just assert the default shape comes back without crashing.
      assert is_map(Worker.status("", nil))
      assert is_map(Workbooks.Keeper.status())
    end
  end
end
