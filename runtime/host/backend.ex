defmodule Workbooks.Backend do
  @moduledoc """
  BYOD — the storage seam (L2 in ARCHITECTURE.org). One behaviour, many impls,
  chosen at deploy time per cell. The runtime depends only on this behaviour;
  a cell swaps `Backend.SQLite` (local/dev) for `Backend.Postgres` (cloud,
  indexed/shared) without touching core. Org files stay the source of truth;
  a Backend is for *derived* storage (search, analytics, presence).

  A handle is the impl's open connection/state, returned by `init/1` and threaded
  through the data calls. The reactive (`subscribe`) and schema (`migrate`)
  callbacks the mainline plan lists are deferred until a cell needs them — added
  to the behaviour then, not carried as dead surface now.
  """

  @type handle :: term()

  @callback init(opts :: keyword()) :: {:ok, handle} | {:error, term()}
  @callback write(handle, collection :: String.t(), doc :: map()) :: {:ok, map()} | {:error, term()}
  @callback read(handle, collection :: String.t(), query :: map()) :: {:ok, [map()]} | {:error, term()}
  @callback query(handle, raw :: String.t(), params :: list()) :: {:ok, [list()]} | {:error, term()}
  @callback close(handle) :: :ok

  @doc """
  The deploy-cell backend table: logical name → {impl, opts}. A cell sets
  `config :workbooks, :backends, [...]`; the default is one in-memory SQLite.
  This is the only place a deploy chooses its storage — see ARCHITECTURE.org §L2.
  """
  def table, do: Application.get_env(:workbooks, :backends, [{:default, Workbooks.Backend.SQLite, [path: ":memory:"]}])

  @doc "Resolve a logical backend name → {impl, opts}."
  def resolve(name \\ :default) do
    case List.keyfind(table(), name, 0) do
      {^name, impl, opts} -> {:ok, impl, opts}
      nil -> {:error, {:no_backend, name}}
    end
  end

  @doc "Open a handle on a named backend (caller closes it)."
  def open(name \\ :default) do
    with {:ok, impl, opts} <- resolve(name),
         {:ok, handle} <- impl.init(opts) do
      {:ok, {impl, handle}}
    end
  end

  # Facade — dispatch a {impl, handle} pair to the chosen backend.
  def write({impl, h}, collection, doc), do: impl.write(h, collection, doc)
  def read({impl, h}, collection, query \\ %{}), do: impl.read(h, collection, query)
  def query({impl, h}, raw, params \\ []), do: impl.query(h, raw, params)
  def close({impl, h}), do: impl.close(h)
end
