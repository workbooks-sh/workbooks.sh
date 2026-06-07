defmodule Workbooks.Lifecycle do
  @moduledoc """
  Instance state machine. created → active → suspended → frozen → archived.
  Transitions are explicit; freeze/resume copy the VFS file (no VM snapshot).
  Litestream replicates the VFS to S3/R2 out of band (external binary).
  """

  @transitions %{
    created: [:active],
    active: [:suspended, :archived],
    suspended: [:active, :frozen],
    frozen: [:active, :archived],
    archived: [:active, :deleted]
  }

  # Auto-transition policy (wb-11ck.23): how long an idle session may sit in a
  # state before the session ticker demotes it. The thresholds are the policy;
  # the driver that applies them on a tick is the SessionRegistry's job.
  @idle_to_suspend 15 * 60
  @idle_to_freeze 24 * 3600

  def states, do: Map.keys(@transitions) ++ [:deleted]

  @doc "Validate a transition; {:ok, to} or {:error, :invalid}."
  def transition(from, to) do
    if to in Map.get(@transitions, from, []), do: {:ok, to}, else: {:error, :invalid}
  end

  @doc """
  Auto-transition for an idle session: the next state given seconds-idle, or nil
  to stay put. Active sessions suspend after idle; suspended sessions freeze after
  a longer idle. A pure policy — the ticker calls it, applies it via `transition/2`.
  """
  def auto_next(:active, idle) when idle >= @idle_to_suspend, do: :suspended
  def auto_next(:suspended, idle) when idle >= @idle_to_freeze, do: :frozen
  def auto_next(_state, _idle), do: nil

  @doc "Clone a Blueprint VFS into a fresh per-Instance VFS file (the base-image model)."
  def clone(blueprint_path, instance_path) do
    File.cp(blueprint_path, instance_path)
  end

  @doc """
  Template clone-per-tenant (wb-11ck.22): copy a read-only base VFS into a fresh
  writable per-tenant file and return its path. Each tenant starts from the same
  seeded template (a Blueprint) but writes to its own isolated copy; the base is
  never mutated.
  """
  def clone_for(base_path, tenant, dir \\ System.tmp_dir!()) do
    dest = Path.join(dir, "tenant-#{tenant}-#{System.unique_integer([:positive])}.sqlite")
    with :ok <- File.cp(base_path, dest), do: {:ok, dest}
  end

  @doc """
  Freeze: persist an Instance's VFS to cold storage. The SQLite file IS the
  durable state — freeze is "stop the process, keep the file", no VM snapshot.
  """
  def freeze(session_id, vfs_path, cold_dir) do
    File.mkdir_p!(cold_dir)
    frozen = Path.join(cold_dir, "#{session_id}.sqlite")
    with :ok <- File.cp(vfs_path, frozen), do: {:ok, frozen}
  end

  @doc """
  Resume: restore an Instance's VFS from cold storage to a live path. The `tmp`
  volume is scratch — it does not survive a resume, so we clear it on restore.
  `workspace` and `memory` persist.
  """
  def resume(session_id, cold_dir, live_dir) do
    frozen = Path.join(cold_dir, "#{session_id}.sqlite")
    live = Path.join(live_dir, "#{session_id}.sqlite")
    File.mkdir_p!(live_dir)

    with :ok <- File.cp(frozen, live) do
      {:ok, conn} = Workbooks.VFS.open(live)
      Workbooks.VFS.clear(conn, "tmp")
      Exqlite.Sqlite3.close(conn)
      {:ok, live}
    end
  end

  @doc """
  Components that declared `:persist` — their state survives a redeploy. Walks the
  recursive plan (worlds + nested sub-workflows) and returns the persistent ones.

  The persistence substrate is the VFS, not raw linear memory. Our components are
  stateless between `run` calls (re-instantiated each Instance start); their
  durable state lives in the VFS, which freeze/resume copies and Litestream
  replicates off-box — both real. So `:persist` is the contract that a component
  checkpoints its state to the VFS (where the runtime guarantees durability),
  rather than a raw-memory snapshot (which doesn't fit a stateless component and
  isn't exposed for component instances). The VFS IS the orthogonal-persistence
  layer; this function tells the runtime which components opt into it.
  """
  def durable_components(%{"worlds" => worlds}), do: Enum.flat_map(worlds, &world_persist/1)
  def durable_components(_), do: []

  defp world_persist(%{"components" => comps} = w) do
    here = comps |> Enum.filter(& &1["persist"]) |> Enum.map(& &1["name"])
    here ++ Enum.flat_map(Map.get(w, "workflows", []), &world_persist/1)
  end
end
