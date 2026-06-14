defmodule Workbooks.ControlPlane do
  @moduledoc """
  The session registry — which Instances exist, their tenant, state, and where
  their VFS lives. SQLite is the control plane (data plane is each Instance's
  VFS). Postgres is only needed if we go multi-machine.
  """
  use GenServer
  alias Exqlite.Sqlite3

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def register(id, tenant, vfs_path),
    do: GenServer.call(__MODULE__, {:register, id, tenant, vfs_path})

  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Instances visible to `tenant` (wb-g1yo.4). Rows are `[id, tenant, state]`. A nil
  caller tenant (admin/internal) sees all; otherwise only this tenant's rows plus
  any legacy rows with no recorded tenant.
  """
  def list(tenant) do
    list()
    |> Enum.filter(fn
      [_id, t, _state] -> Workbooks.Tenant.visible?(t, tenant)
      _ -> true
    end)
  end

  @doc "Fetch a session row → %{id, tenant, state, vfs_path} | nil."
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Update a session's lifecycle state (created/active/suspended/frozen/...)."
  def set_state(id, state), do: GenServer.call(__MODULE__, {:set_state, id, state})

  @doc "Store / load a Workbook's Org source by id (the deployable artifact). `tenant` scopes ownership (wb-g1yo.9)."
  def put_workbook(id, org, tenant \\ nil), do: GenServer.call(__MODULE__, {:put_workbook, id, org, tenant})
  def get_workbook(id), do: GenServer.call(__MODULE__, {:get_workbook, id})

  @doc "The owning tenant of a workbook → string | nil (legacy) | :not_found."
  def workbook_tenant(id), do: GenServer.call(__MODULE__, {:workbook_tenant, id})

  @doc "All workbook rows (%{id, tenant}). list_workbooks/1 scopes to a tenant (nil = all/admin; legacy nil-tenant rows grandfathered)."
  def list_workbooks, do: GenServer.call(__MODULE__, :list_workbooks)

  def list_workbooks(tenant) do
    list_workbooks()
    |> Enum.filter(fn %{tenant: t} -> is_nil(tenant) or is_nil(t) or t == tenant end)
  end

  @doc "May `caller_tenant` read workbook `id`? Same grandfather rule as the rest of wb-g1yo."
  def workbook_visible?(id, caller_tenant) do
    case workbook_tenant(id) do
      :not_found -> true
      t -> Workbooks.Tenant.visible?(t, caller_tenant)
    end
  end

  # --- Shared-folder grants (Phase 3) -----------------------------------------
  # A grant = "owner_tenant shares folder with recipient_tenant (read|draft)". The
  # id is a stable content hash so re-sharing the same triple is idempotent (no
  # Date/random needed). Policy + confinement live in `Workbooks.Workspace`; this
  # is only the registry. UNLIKE workbook visibility, a grant is the SOLE thing
  # that lets data cross a tenant boundary — and only for the one named folder.

  @doc "Record (idempotently) that `owner` shares `folder` with `recipient` in `mode`. Returns the grant."
  def put_share(owner, folder, recipient, mode),
    do: GenServer.call(__MODULE__, {:put_share, owner, folder, recipient, mode})

  @doc "A single grant by id → %{id, owner, folder, recipient, mode} | nil."
  def get_share(id), do: GenServer.call(__MODULE__, {:get_share, id})

  @doc "Grants OWNED by `tenant` (folders it shares out)."
  def shares_by(tenant), do: GenServer.call(__MODULE__, {:shares_by, tenant})

  @doc "Grants made TO `tenant` (folders shared with it, addable to its workspace)."
  def shares_for(tenant), do: GenServer.call(__MODULE__, {:shares_for, tenant})

  @doc "Revoke a grant by id (future adds are blocked; already-vendored Drafts are the recipient's own)."
  def delete_share(id), do: GenServer.call(__MODULE__, {:delete_share, id})

  @doc "Stable grant id for a triple (owner/folder→recipient) — idempotent, no timestamp."
  def share_id(owner, folder, recipient) do
    :crypto.hash(:sha256, "#{owner}/shared/#{folder}->#{recipient}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @impl true
  def init(_) do
    {:ok, conn} = Sqlite3.open(System.get_env("WB_REGISTRY", ":memory:"))

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS instances (
        id TEXT PRIMARY KEY, tenant TEXT, state TEXT, vfs_path TEXT, updated INTEGER
      )
      """)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS workbooks (id TEXT PRIMARY KEY, org TEXT, created INTEGER, tenant TEXT)
      """)

    # Migration (wb-g1yo.9): add the tenant column to a pre-existing workbooks
    # table. Errors if it already exists (fresh DBs from the CREATE above) — that's
    # fine, swallow it so init is idempotent.
    _ = Sqlite3.execute(conn, "ALTER TABLE workbooks ADD COLUMN tenant TEXT")

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS shares (
        id TEXT PRIMARY KEY, owner_tenant TEXT, folder TEXT,
        recipient_tenant TEXT, mode TEXT, created INTEGER
      )
      """)

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:register, id, tenant, vfs_path}, _from, %{conn: conn} = s) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT OR REPLACE INTO instances VALUES (?1, ?2, 'created', ?3, ?4)"
      )

    :ok = Sqlite3.bind(stmt, [id, tenant, vfs_path, System.system_time(:second)])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, :ok, s}
  end

  def handle_call(:list, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, tenant, state FROM instances")
    rows = drain(conn, stmt, [])
    Sqlite3.release(conn, stmt)
    {:reply, rows, s}
  end

  def handle_call({:get, id}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, tenant, state, vfs_path FROM instances WHERE id = ?1")
    :ok = Sqlite3.bind(stmt, [id])

    reply =
      case Sqlite3.step(conn, stmt) do
        {:row, [id, tenant, state, vfs_path]} ->
          %{id: id, tenant: tenant, state: state, vfs_path: vfs_path}

        :done ->
          nil
      end

    Sqlite3.release(conn, stmt)
    {:reply, reply, s}
  end

  def handle_call({:set_state, id, state}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "UPDATE instances SET state = ?1, updated = ?2 WHERE id = ?3")
    :ok = Sqlite3.bind(stmt, [state, System.system_time(:second), id])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, :ok, s}
  end

  def handle_call({:put_workbook, id, org, tenant}, _from, %{conn: conn} = s) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "INSERT OR REPLACE INTO workbooks (id, org, created, tenant) VALUES (?1, ?2, ?3, ?4)")

    :ok = Sqlite3.bind(stmt, [id, org, System.system_time(:second), tenant])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, :ok, s}
  end

  # The owning tenant of a workbook (wb-g1yo.9) → string | nil (legacy) | :not_found.
  def handle_call({:workbook_tenant, id}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT tenant FROM workbooks WHERE id = ?1")
    :ok = Sqlite3.bind(stmt, [id])

    reply =
      case Sqlite3.step(conn, stmt) do
        {:row, [t]} -> t
        _ -> :not_found
      end

    Sqlite3.release(conn, stmt)
    {:reply, reply, s}
  end

  def handle_call({:get_workbook, id}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT org FROM workbooks WHERE id = ?1")
    :ok = Sqlite3.bind(stmt, [id])

    reply =
      case Sqlite3.step(conn, stmt) do
        {:row, [org]} -> org
        :done -> nil
      end

    Sqlite3.release(conn, stmt)
    {:reply, reply, s}
  end

  def handle_call(:list_workbooks, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, tenant FROM workbooks ORDER BY created DESC")
    rows = drain(conn, stmt, []) |> Enum.map(fn [id, t] -> %{id: id, tenant: t} end)
    Sqlite3.release(conn, stmt)
    {:reply, rows, s}
  end

  def handle_call({:put_share, owner, folder, recipient, mode}, _from, %{conn: conn} = s) do
    id = share_id(owner, folder, recipient)
    {:ok, stmt} =
      Sqlite3.prepare(conn, "INSERT OR REPLACE INTO shares VALUES (?1, ?2, ?3, ?4, ?5, ?6)")

    :ok = Sqlite3.bind(stmt, [id, owner, folder, recipient, to_string(mode), System.system_time(:second)])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, %{id: id, owner: owner, folder: folder, recipient: recipient, mode: to_string(mode)}, s}
  end

  def handle_call({:get_share, id}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id, owner_tenant, folder, recipient_tenant, mode FROM shares WHERE id = ?1")
    :ok = Sqlite3.bind(stmt, [id])

    reply =
      case Sqlite3.step(conn, stmt) do
        {:row, [id, o, f, r, m]} -> %{id: id, owner: o, folder: f, recipient: r, mode: m}
        :done -> nil
      end

    Sqlite3.release(conn, stmt)
    {:reply, reply, s}
  end

  def handle_call({:shares_by, tenant}, _from, %{conn: conn} = s),
    do: {:reply, share_rows(conn, "owner_tenant", tenant), s}

  def handle_call({:shares_for, tenant}, _from, %{conn: conn} = s),
    do: {:reply, share_rows(conn, "recipient_tenant", tenant), s}

  def handle_call({:delete_share, id}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "DELETE FROM shares WHERE id = ?1")
    :ok = Sqlite3.bind(stmt, [id])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, :ok, s}
  end

  # `column` is interpolated into the SQL, so it MUST stay a fixed internal literal
  # (only "owner_tenant" / "recipient_tenant" from shares_by/shares_for) — never a
  # caller value. Allow-listed here so a future caller can't smuggle SQL through it.
  defp share_rows(conn, column, tenant) when column in ["owner_tenant", "recipient_tenant"] do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "SELECT id, owner_tenant, folder, recipient_tenant, mode FROM shares WHERE #{column} = ?1 ORDER BY created DESC")

    :ok = Sqlite3.bind(stmt, [tenant])
    rows = drain(conn, stmt, []) |> Enum.map(fn [id, o, f, r, m] -> %{id: id, owner: o, folder: f, recipient: r, mode: m} end)
    Sqlite3.release(conn, stmt)
    rows
  end

  defp drain(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> drain(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
