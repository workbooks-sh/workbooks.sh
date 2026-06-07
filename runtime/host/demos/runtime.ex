defmodule Workbooks.Demos.Runtime do
  @moduledoc "Demos for the Instance runtime: isolation, the spine, VFS volumes, freeze/resume, CPU caps."

  @doc "Freeze/resume demo: data in a VFS survives a freeze → resume cycle."
  def demo_freeze do
    dir = Path.join(System.tmp_dir!(), "wb-demo-#{System.unique_integer([:positive])}")
    live = Path.join(dir, "s1.sqlite")
    File.mkdir_p!(dir)
    {:ok, conn} = Workbooks.VFS.open(live)
    Workbooks.VFS.put(conn, "/note.txt", "survives")
    {:ok, _} = Workbooks.Lifecycle.freeze("s1", live, Path.join(dir, "cold"))
    {:ok, restored} = Workbooks.Lifecycle.resume("s1", Path.join(dir, "cold"), Path.join(dir, "live2"))
    {:ok, conn2} = Workbooks.VFS.open(restored)
    Workbooks.VFS.get(conn2, "/note.txt")
  end

  @doc """
  Isolation demo: two Instances run the SAME engine-world component, each over its
  own VFS + Policy, calling back through the typed Dock — proving capability
  imports work and that a's VFS query never returns b's rows.
  """
  def demo_isolation do
    bytes = File.read!("build/fixtures/engine-probe.wasm")
    {:ok, _} = Workbooks.Instance.Supervisor.start_instance("a", bytes, policy: :minimal)
    {:ok, _} = Workbooks.Instance.Supervisor.start_instance("b", bytes, policy: :network)
    Workbooks.Instance.vfs_put("a", "/alpha", "1")
    Workbooks.Instance.vfs_put("b", "/beta", "1")
    {:ok, a_run} = Workbooks.Instance.call("a", "run", ["hi-a"])
    {:ok, b_run} = Workbooks.Instance.call("b", "run", ["hi-b"])

    %{
      a_saw: Jason.decode!(a_run),
      b_saw: Jason.decode!(b_run),
      a_caps: Workbooks.Instance.info("a").caps,
      b_caps: Workbooks.Instance.info("b").caps
    }
  end

  # The product spine: a Workbook whose :component: targets the workbooks:engine
  # world (a Cargo crate with [package.metadata.component]).
  @workbook_app """
  * Probe app                                         :workflow:
  ** Probe                                            :component:
     #+begin_src rust :dir examples/engine-probe
     #+end_src
  """

  @doc """
  Workbook spine demo: tangle a Workbook, build its component (engine world, via
  cargo-component), load it into a fresh Instance, and call `run` — which calls
  back through the Dock. The component is produced by the runtime's own build path.
  """
  def demo_workbook do
    [{name, _lang, result}] = Workbooks.PackageManager.tangle(@workbook_app)

    case result do
      {:ok, wasm, how} ->
        id = "wb-#{System.unique_integer([:positive])}"
        {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, File.read!(wasm), policy: :minimal)
        Workbooks.Instance.vfs_put(id, "/readme", "hi")
        {:ok, ran} = Workbooks.Instance.call(id, "run", ["spine"])
        %{component: name, built: how, ran: Jason.decode!(ran)}

      other ->
        %{component: name, error: other}
    end
  end

  @doc """
  Named-volumes demo (wb-11ck.17): one Instance, three volumes (workspace/memory/
  tmp). The same path holds different content per volume; freeze→resume keeps
  workspace + memory but clears tmp (scratch).
  """
  def demo_volumes do
    id = "vol-#{System.unique_integer([:positive])}"
    cold = Path.join(System.tmp_dir!(), "wb-cold-#{id}")
    live = Path.join(System.tmp_dir!(), "wb-live-#{id}")
    db = Path.join(System.tmp_dir!(), "#{id}.sqlite")
    {:ok, conn} = Workbooks.VFS.open(db)
    Workbooks.VFS.put(conn, "/note", "the workbook files", "workspace")
    Workbooks.VFS.put(conn, "/note", "what the agent learned", "memory")
    Workbooks.VFS.put(conn, "/note", "scratch", "tmp")
    Exqlite.Sqlite3.close(conn)

    File.mkdir_p!(cold)
    {:ok, _} = Workbooks.Lifecycle.freeze(id, db, cold)
    {:ok, restored} = Workbooks.Lifecycle.resume(id, cold, live)
    {:ok, r} = Workbooks.VFS.open(restored)

    %{
      volumes: Workbooks.VFS.volumes(),
      workspace: Workbooks.VFS.get(r, "/note", "workspace"),
      memory: Workbooks.VFS.get(r, "/note", "memory"),
      tmp_after_resume: Workbooks.VFS.get(r, "/note", "tmp")
    }
  end

  @doc """
  Template clone-per-tenant demo (wb-11ck.22): seed a read-only base VFS, clone it
  for two tenants, each writes to its own copy — both inherit the seed, neither
  sees the other's write, the base is never mutated.
  """
  def demo_template do
    base = Path.join(System.tmp_dir!(), "base-#{System.unique_integer([:positive])}.sqlite")
    {:ok, conn} = Workbooks.VFS.open(base)
    Workbooks.VFS.put(conn, "/seed", "from the template")
    Exqlite.Sqlite3.close(conn)

    {:ok, a} = Workbooks.Lifecycle.clone_for(base, "acme")
    {:ok, b} = Workbooks.Lifecycle.clone_for(base, "globex")
    {:ok, ca} = Workbooks.VFS.open(a)
    {:ok, cb} = Workbooks.VFS.open(b)
    Workbooks.VFS.put(ca, "/own", "acme only")
    Workbooks.VFS.put(cb, "/own", "globex only")

    %{
      a_seed: Workbooks.VFS.get(ca, "/seed"),
      a_own: Workbooks.VFS.get(ca, "/own"),
      a_sees_b: Workbooks.VFS.get(ca, "/own") == Workbooks.VFS.get(cb, "/own"),
      base_untouched: match?(:error, (fn -> {:ok, c} = Workbooks.VFS.open(base); Workbooks.VFS.get(c, "/own") end).())
    }
  end

  @doc "Auto-transition policy demo (wb-11ck.23): the ticker demotes idle sessions."
  def demo_auto_transitions do
    %{
      active_idle_16m: Workbooks.Lifecycle.auto_next(:active, 16 * 60),
      active_fresh: Workbooks.Lifecycle.auto_next(:active, 60),
      suspended_idle_2d: Workbooks.Lifecycle.auto_next(:suspended, 2 * 24 * 3600),
      frozen_stays: Workbooks.Lifecycle.auto_next(:frozen, 999_999)
    }
  end

  @doc """
  Session resume demo (wb-11ck.24): register a session, resume it twice. First is
  COLD (restore VFS + start, state→active); second is WARM (live Instance reused).
  """
  def demo_resume do
    id = "sess-#{System.unique_integer([:positive])}"
    bytes = File.read!("build/fixtures/engine-probe.wasm")
    Workbooks.ControlPlane.register(id, "acme", ":memory:")
    first = Workbooks.Sessions.resume(id, bytes, policy: :minimal)
    second = Workbooks.Sessions.resume(id, bytes, policy: :minimal)

    %{
      first_resume: first,
      second_resume: second,
      warm_now: Workbooks.Sessions.warm?(id),
      state: Workbooks.ControlPlane.get(id).state
    }
  end

  @doc """
  Component CPU cap demo (wb-11ck.13, no fork): a runaway component (`run("spin")`)
  is trapped at its wall-clock budget → {:error, :cpu_timeout}, and the BEAM stays
  responsive (a second Instance answers right after).
  """
  def demo_cpu_cap do
    bytes = File.read!("build/fixtures/engine-probe.wasm")
    {:ok, _} = Workbooks.Instance.Supervisor.start_instance("runaway", bytes, policy: :minimal, timeout: 800)
    t = System.monotonic_time(:millisecond)
    trapped = Workbooks.Instance.call("runaway", "run", ["spin"])
    elapsed = System.monotonic_time(:millisecond) - t

    {:ok, _} = Workbooks.Instance.Supervisor.start_instance("healthy", bytes, policy: :minimal)
    {:ok, ok} = Workbooks.Instance.call("healthy", "run", ["after"])

    %{
      runaway: trapped,
      trapped_in_ms: elapsed,
      beam_responsive_after: Jason.decode!(ok)["input"] == "after"
    }
  end

  @doc """
  Fuel demo: an infinite-loop core module traps on its fuel budget. Fuel is a
  core-module-store capability, so this runs the raw module directly — the same
  mechanism the Package Manager uses to cap tool modules.
  """
  def demo_fuel do
    bytes = File.read!("build/loop.wasm")
    config = Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true)
    {:ok, engine} = Wasmex.Engine.new(config)
    {:ok, store} = Wasmex.Store.new(%Wasmex.StoreLimits{}, engine)
    :ok = Wasmex.StoreOrCaller.set_fuel(store, 5_000_000)
    {:ok, module} = Wasmex.Module.compile(store, bytes)
    {:ok, pid} = Wasmex.start_link(%{store: store, module: module})
    t = System.monotonic_time(:millisecond)
    {tag, _} = Wasmex.call_function(pid, "run", [])
    %{outcome: tag, ms: System.monotonic_time(:millisecond) - t, trapped: tag == :error, beam_alive: true}
  end
end
