defmodule Workbooks.DB do
  @moduledoc """
  BYO-database seam for the STRUCTURED stores (vars, agent memory, the
  telemetry/ledger index, the registry). SQLite by default (the simple single-box
  deploy); Postgres the moment `WB_DATABASE_URL` is set — and ANY Postgres
  provider works because it's just a connection URL: CrunchyData, Fly PG, Railway,
  Neon, Supabase are indistinguishable to the runtime. One code path, no
  per-provider branches. See docs/DEPLOY-KIT-STORAGE.org.

  A store opens a handle and runs portable SQL with `?1/?2` placeholders;
  `Workbooks.DB` translates them to `$1/$2` for Postgres. Rows come back as lists
  either way, so a store's query code is identical across backends.
  """
  alias Exqlite.Sqlite3

  @doc "The active backend: :postgres when WB_DATABASE_URL is set, else :sqlite."
  def backend, do: if(url(), do: :postgres, else: :sqlite)

  @doc "Open a named structured store → a tagged handle ({:postgres, pid} | {:sqlite, conn})."
  def open(name) do
    case backend() do
      :postgres ->
        {:ok, pid} = Postgrex.start_link(url_opts(url()))
        {:postgres, pid}

      :sqlite ->
        path = Path.join([System.get_env("WB_DATA", "tmp/data"), "_db", "#{name}.sqlite"])
        File.mkdir_p!(Path.dirname(path))
        {:ok, conn} = Sqlite3.open(path)
        {:sqlite, conn}
    end
  end

  @doc "Run DDL / a no-result statement."
  def execute({:postgres, pid}, sql), do: (Postgrex.query!(pid, pg(sql), []); :ok)
  def execute({:sqlite, conn}, sql), do: Sqlite3.execute(conn, sql)

  @doc "Run a parameterized query → list of row lists (backend-uniform)."
  def query(handle, sql, params \\ [])
  def query({:postgres, pid}, sql, params), do: Postgrex.query!(pid, pg(sql), params).rows

  def query({:sqlite, conn}, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    if params != [], do: Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    Sqlite3.release(conn, stmt)
    rows
  end

  # `?1 ?2` (SQLite/portable) → `$1 $2` (Postgres). Same numbers, different sigil.
  @doc false
  def pg(sql), do: Regex.replace(~r/\?(\d+)/, sql, "$\\1")

  defp url, do: (case System.get_env("WB_DATABASE_URL"), do: (u when is_binary(u) and u != "" -> u; _ -> nil))

  # Parse a postgres:// URL into Postgrex opts. Hosted providers need SSL, so
  # default it on for non-local hosts (sslmode=disable in the URL turns it off).
  defp url_opts(u) do
    uri = URI.parse(u)
    [user, pass] = case uri.userinfo, do: (nil -> ["postgres", nil]; ui -> String.split(ui, ":", parts: 2) ++ [nil] |> Enum.take(2))
    ssl? = uri.host not in ["localhost", "127.0.0.1"] and not String.contains?(u, "sslmode=disable")

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: String.trim_leading(uri.path || "/postgres", "/"),
      ssl: ssl?
    ]
  end
end
