defmodule Workbooks.Vars do
  @moduledoc """
  The runtime variable store + ref, per tenant. Variables are key→value; some are
  *secrets* — ref-only, never returned to a guest, only injected on egress (the
  secrets-by-reference rule, docs/SECRETS.md). `ref/2` substitutes `{{var:KEY}}`
  and `{{secret:KEY}}` host-side; `get/2` redacts secret values. The `wb var` CLI
  manages them and an agent references a secret without ever holding its bytes.
  """
  use GenServer
  alias Exqlite.Sqlite3

  @ref ~r/\{\{(var|secret):([A-Za-z0-9_]+)\}\}/

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Set a variable (secret? marks it ref-only)."
  def set(tenant, key, value, secret? \\ false),
    do: GenServer.call(__MODULE__, {:set, tenant, key, value, secret?})

  @doc "Get a variable. Secret values come back `{:secret, :redacted}` — ref them, don't read them."
  def get(tenant, key), do: GenServer.call(__MODULE__, {:get, tenant, key})

  @doc "List a tenant's variables as %{key => :plain | :secret}."
  def list(tenant), do: GenServer.call(__MODULE__, {:list, tenant})

  @doc """
  HOST-ONLY raw read of a tenant's value (plain OR secret) for egress. Returns the
  plaintext string, or `nil` if unset. NEVER expose this to a guest — it bypasses the
  secret redaction `get/2` enforces. Used host-side (e.g. resolving a tenant's own
  OPENROUTER_API_KEY for an LLM egress) where the value never crosses the membrane.
  Returns `nil` (not crash) when the store isn't running, so callers fall back cleanly.
  """
  def host_secret(tenant, key) do
    GenServer.call(__MODULE__, {:host_secret, tenant, key})
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  Inject `{{var:KEY}}` / `{{secret:KEY}}` from the store into a template.
  `:guest` (default) resolves plain vars but leaves SECRET placeholders intact —
  an agent never sees a secret's plaintext. `:host` resolves everything and is
  used only at egress (e.g. inside net-fetch), outside the guest's reach.
  """
  def ref(tenant, template, mode \\ :guest),
    do: GenServer.call(__MODULE__, {:ref, tenant, template, mode})

  @impl true
  def init(_) do
    {:ok, conn} = Sqlite3.open(System.get_env("WB_VARS", ":memory:"))
    :ok = Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS vars (tenant TEXT, key TEXT, value TEXT, secret INTEGER, PRIMARY KEY(tenant,key))")
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:set, tenant, key, value, secret?}, _from, %{conn: c} = s) do
    exec(c, "INSERT OR REPLACE INTO vars VALUES (?1,?2,?3,?4)", [tenant, key, value, if(secret?, do: 1, else: 0)])
    {:reply, :ok, s}
  end

  def handle_call({:get, tenant, key}, _from, %{conn: c} = s) do
    reply =
      case row(c, "SELECT value, secret FROM vars WHERE tenant=?1 AND key=?2", [tenant, key]) do
        [value, 1] -> {:secret, :redacted, byte_size(value)}
        [value, 0] -> {:ok, value}
        nil -> :error
      end

    {:reply, reply, s}
  end

  def handle_call({:host_secret, tenant, key}, _from, %{conn: c} = s) do
    reply =
      case row(c, "SELECT value FROM vars WHERE tenant=?1 AND key=?2", [tenant, key]) do
        [value] -> value
        nil -> nil
      end

    {:reply, reply, s}
  end

  def handle_call({:list, tenant}, _from, %{conn: c} = s) do
    rows = all(c, "SELECT key, secret FROM vars WHERE tenant=?1 ORDER BY key", [tenant])
    {:reply, Map.new(rows, fn [k, sec] -> {k, if(sec == 1, do: :secret, else: :plain)} end), s}
  end

  def handle_call({:ref, tenant, template, mode}, _from, %{conn: c} = s) do
    out =
      Regex.replace(@ref, template, fn whole, kind, key ->
        # Guest-facing: a secret stays an opaque placeholder; only :host (egress) resolves it.
        if kind == "secret" and mode == :guest do
          whole
        else
          case row(c, "SELECT value FROM vars WHERE tenant=?1 AND key=?2", [tenant, key]) do
            [value] -> value
            nil -> whole
          end
        end
      end)

    {:reply, out, s}
  end

  defp exec(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(c, stmt)
    Sqlite3.release(c, stmt)
  end

  defp row(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)
    :ok = Sqlite3.bind(stmt, params)

    r =
      case Sqlite3.step(c, stmt) do
        {:row, row} -> row
        :done -> nil
      end

    Sqlite3.release(c, stmt)
    r
  end

  defp all(c, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(c, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(c, stmt)
    Sqlite3.release(c, stmt)
    rows
  end
end
