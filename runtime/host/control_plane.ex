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

  @doc "Fetch a session row → %{id, tenant, state, vfs_path} | nil."
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Update a session's lifecycle state (created/active/suspended/frozen/...)."
  def set_state(id, state), do: GenServer.call(__MODULE__, {:set_state, id, state})

  @doc "Store / load a Workbook's Org source by id (the deployable artifact)."
  def put_workbook(id, org), do: GenServer.call(__MODULE__, {:put_workbook, id, org})
  def get_workbook(id), do: GenServer.call(__MODULE__, {:get_workbook, id})
  def list_workbooks, do: GenServer.call(__MODULE__, :list_workbooks)

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
      CREATE TABLE IF NOT EXISTS workbooks (id TEXT PRIMARY KEY, org TEXT, created INTEGER)
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

  def handle_call({:put_workbook, id, org}, _from, %{conn: conn} = s) do
    {:ok, stmt} = Sqlite3.prepare(conn, "INSERT OR REPLACE INTO workbooks VALUES (?1, ?2, ?3)")
    :ok = Sqlite3.bind(stmt, [id, org, System.system_time(:second)])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    {:reply, :ok, s}
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
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT id FROM workbooks ORDER BY created DESC")
    ids = drain(conn, stmt, []) |> Enum.map(fn [id] -> id end)
    Sqlite3.release(conn, stmt)
    {:reply, ids, s}
  end

  defp drain(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> drain(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
