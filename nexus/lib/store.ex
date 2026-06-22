defmodule Nexus.Store do
  @moduledoc """
  The **universal persistence adapter** — the seam behind the typed-struct base (`Nexus.Resource`).
  A `resource` compiles to a plain struct (the shape, client + server, no deps); *where* its rows
  live is a swappable backend behind this one interface:

    * **default** — `Nexus.Store.Ets`, in-memory, zero deps (great for local/dev/tests)
    * **durable** — `Nexus.Store.Sqlite`; **cloud** — Neon Postgres; a wasm-SQL engine — all behind
      the same callbacks. The struct is the Elixir representation every backend fields into.

  **Every row is partitioned by TENANT.** All operations take a `tenant` (default `"default"` for
  single-tenant/local). A request's tenant comes from `Nexus.Auth`; one tenant can never read or
  write another's rows — isolation is enforced in the store, not hoped for upstream. That makes the
  data layer multi-tenant-native: single-tenant is just everyone on `"default"`.

  Configure with `config :nexus, store_adapter: SomeAdapter` (defaults to ETS).
  """

  @type tenant :: String.t()

  @callback create(resource :: module, attrs :: map, tenant) :: {:ok, struct} | {:error, term}
  @callback all(resource :: module, tenant) :: [struct]
  @callback count(resource :: module, tenant) :: non_neg_integer
  @callback clear(resource :: module, tenant) :: :ok

  # Optional schema introspection — the real columns a resource has in this backend.
  # A COLUMNAR backend (Postgres/Neon: `SELECT column_name FROM information_schema.columns
  # WHERE table_name = $1`) implements this so `Nexus.Schema` can diff the live table
  # against the declared `__fields__` (data drift). Row-blob backends (ETS/SQLite) omit
  # it — they faithfully store the declared struct, so there are no columns to drift.
  @callback columns(resource :: module, tenant) :: [String.t()]

  # Optional native pagination. A backend that can page/filter/sort more efficiently than
  # "load all → slice" (e.g. SQLite `LIMIT/OFFSET` for the default browse case) implements this.
  # Backends that omit it get the generic `Nexus.Store.Page` fallback over `all/2`.
  @callback page(resource :: module, tenant, opts :: keyword) :: {[struct], non_neg_integer}
  @optional_callbacks columns: 2, page: 3

  @default "default"

  @doc "Validate `attrs` against the resource's shape and persist a row for `tenant`."
  def create(resource, attrs, tenant \\ @default) do
    out = adapter().create(resource, attrs, tenant)
    instrument(resource, tenant)
    out
  end

  @tagreg {__MODULE__, :tags}

  @doc "Register a resource module's #tags (set at compile; keeps the struct minimal). Used for #event."
  def register_tags(module, tags) when is_atom(module) and is_list(tags) do
    :persistent_term.put(@tagreg, Map.put(tags_map(), module, tags))
    :ok
  end

  defp tags_map, do: :persistent_term.get(@tagreg, %{})

  # #event auto-instrument: a #event-tagged resource emits a write event (its other #tags ride along).
  defp instrument(resource, tenant) do
    tags = Map.get(tags_map(), resource, [])

    if "event" in tags do
      Nexus.Events.instrument(
        %{kind: "resource", name: resource, refs: Enum.map(tags, &("#" <> &1))},
        %{kind: "resource.create", title: inspect(resource), tenant: tenant}
      )
    end
  rescue
    _ -> :ok
  end

  @doc "All rows of a resource visible to `tenant`."
  def all(resource, tenant \\ @default), do: adapter().all(resource, tenant)

  @doc "How many rows a resource has for `tenant`."
  def count(resource, tenant \\ @default), do: adapter().count(resource, tenant)

  @doc """
  A page of a resource's rows for `tenant`. Returns `{rows, total}` where `total` is the count
  AFTER any `:q` filter. Opts: `:offset` (>=0), `:limit` (1..500, default 50), `:sort`
  (`{field, :asc|:desc}` or a field name; defaults to insertion order), `:q` (substring search
  across decoded fields). Uses the backend's native `page/3` when available, else slices `all/2`.
  """
  def page(resource, tenant \\ @default, opts \\ []) do
    a = adapter()

    if function_exported?(a, :page, 3) do
      a.page(resource, tenant, opts)
    else
      Nexus.Store.Page.apply(a.all(resource, tenant), opts)
    end
  end

  @doc "Drop a resource's rows for `tenant` (never touches other tenants)."
  def clear(resource, tenant \\ @default), do: adapter().clear(resource, tenant)

  @doc "The configured backend (default `Nexus.Store.Ets`)."
  def adapter, do: Application.get_env(:nexus, :store_adapter, Nexus.Store.Ets)

  @doc "The single-tenant / fallback tenant id."
  def default_tenant, do: @default
end
