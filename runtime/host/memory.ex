defmodule Workbooks.Memory do
  @moduledoc """
  Agent long-term memory, per tenant (brandnana's `wb memory`). Findings persist
  across runs so the second time an agent works a topic it has the first run's
  research as a prior. `remember` upserts a keyed note; `recall` fetches one;
  `search` does a substring match over content. SQLite-backed (set `WB_MEMORY` to
  a path for cross-process durability; `:memory:` keeps it for the app's life).
  """
  use GenServer
  alias Exqlite.Sqlite3

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def remember(tenant, key, content), do: GenServer.call(__MODULE__, {:remember, tenant, key, content})
  def recall(tenant, key), do: GenServer.call(__MODULE__, {:recall, tenant, key})
  def search(tenant, query), do: GenServer.call(__MODULE__, {:search, tenant, query})

  @impl true
  def init(_) do
    {:ok, conn} = Sqlite3.open(System.get_env("WB_MEMORY", ":memory:"))
    :ok = Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS memory (tenant TEXT, key TEXT, content TEXT, created INTEGER, PRIMARY KEY(tenant,key))")
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:remember, tenant, key, content}, _from, %{conn: c} = s) do
    {:ok, stmt} = Sqlite3.prepare(c, "INSERT OR REPLACE INTO memory VALUES (?1,?2,?3,?4)")
    :ok = Sqlite3.bind(stmt, [tenant, key, content, System.system_time(:second)])
    :done = Sqlite3.step(c, stmt)
    Sqlite3.release(c, stmt)
    {:reply, :ok, s}
  end

  def handle_call({:recall, tenant, key}, _from, %{conn: c} = s) do
    {:reply, scalar(c, "SELECT content FROM memory WHERE tenant=?1 AND key=?2", [tenant, key]), s}
  end

  def handle_call({:search, tenant, query}, _from, %{conn: c} = s) do
    {:ok, stmt} = Sqlite3.prepare(c, "SELECT key, content FROM memory WHERE tenant=?1 AND content LIKE ?2 ORDER BY created DESC LIMIT 10")
    :ok = Sqlite3.bind(stmt, [tenant, "%#{query}%"])
    {:ok, rows} = Sqlite3.fetch_all(c, stmt)
    Sqlite3.release(c, stmt)
    {:reply, Enum.map(rows, fn [k, v] -> %{key: k, content: v} end), s}
  end

  defp scalar(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)
    :ok = Sqlite3.bind(stmt, params)

    r =
      case Sqlite3.step(c, stmt) do
        {:row, [v]} -> v
        :done -> nil
      end

    Sqlite3.release(c, stmt)
    r
  end
end
