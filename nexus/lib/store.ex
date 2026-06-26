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

  # Optional in-place update. A backend that can mutate rows efficiently implements it; backends
  # that omit it get the generic load → clear → recreate fallback in `update/4`. `match` selects
  # rows by field equality; `changes` is merged into each matched row.
  @callback update(resource :: module, match :: map, changes :: map, tenant) :: :ok

  # Optional native delete. A backend that can remove rows efficiently implements it; backends that
  # omit it get the generic load → clear → recreate-survivors fallback in `delete/3`. `match` selects
  # the rows to remove by field equality.
  @callback delete(resource :: module, match :: map, tenant) :: :ok
  @optional_callbacks columns: 2, page: 3, update: 4, delete: 3

  @default "default"
  # Sentinel for "caller did not pass a tenant" — distinct from an EXPLICIT "default", so we can fail
  # closed on omission on a multi-tenant nexus while honoring an explicit choice (see resolve_tenant/1).
  @omitted :__tenant_omitted__

  @doc "Validate `attrs` against the resource's shape and persist a row for `tenant`."
  def create(resource, attrs, tenant \\ @omitted) do
    tenant = resolve_tenant(tenant)
    out = adapter().create(resource, attrs, tenant)
    instrument(resource, tenant)
    # Live-shapes: push an :insert delta to any open subscription on {tenant, resource} (no-op when
    # nobody is watching). Only on a successful write, carrying the persisted row.
    case out do
      {:ok, row} -> Nexus.Shapes.notify(resource, tenant, :insert, row)
      _ -> :ok
    end

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
  def all(resource, tenant \\ @omitted), do: adapter().all(resource, resolve_tenant(tenant))

  @doc "How many rows a resource has for `tenant`."
  def count(resource, tenant \\ @omitted), do: adapter().count(resource, resolve_tenant(tenant))

  @doc """
  A page of a resource's rows for `tenant`. Returns `{rows, total}` where `total` is the count
  AFTER any `:q` filter. Opts: `:offset` (>=0), `:limit` (1..500, default 50), `:sort`
  (`{field, :asc|:desc}` or a field name; defaults to insertion order), `:q` (substring search
  across decoded fields), `:order` (`:asc`|`:desc` insertion order — `:desc` is newest-first, the
  history cold-load case), `:before`/`:after` (a row-id KEYSET cursor — O(limit) scroll-back that
  stays flat as a channel grows, vs `:offset` which scans-and-skips; SQLite-native only). Uses the
  backend's native `page/3` when available, else slices `all/2`.
  """
  def page(resource, tenant \\ @omitted, opts \\ []) do
    a = adapter()
    tenant = resolve_tenant(tenant)

    if function_exported?(a, :page, 3) do
      a.page(resource, tenant, opts)
    else
      Nexus.Store.Page.apply(a.all(resource, tenant), opts)
    end
  end

  @doc "Drop a resource's rows for `tenant` (never touches other tenants)."
  def clear(resource, tenant \\ @omitted), do: adapter().clear(resource, resolve_tenant(tenant))

  @doc """
  Update rows of `resource` matching `match` (field equality) by merging `changes` into each.
  Uses the backend's native `update/4` when available, else the generic load → clear → recreate
  fallback (fine for small/low-frequency tables like the hash-note drawer). Returns `:ok`.
  """
  def update(resource, match, changes, tenant \\ @omitted) when is_map(match) and is_map(changes) do
    a = adapter()
    tenant = resolve_tenant(tenant)

    # Post-image of each matched row, computed BEFORE the write so we can emit a faithful per-row delta.
    # A full row (not just the merged changes) carries the shape's scope field, so a scoped subscriber's
    # filter passes — a coarse {match ∪ changes} delta drops out of every channel/message-scoped shape.
    post =
      a.all(resource, tenant)
      |> Enum.filter(&matches?(&1, match))
      |> Enum.map(&struct(&1, changes))

    if function_exported?(a, :update, 4) do
      a.update(resource, match, changes, tenant)
    else
      rows =
        Enum.map(a.all(resource, tenant), fn row ->
          if matches?(row, match), do: struct(row, changes), else: row
        end)

      a.clear(resource, tenant)
      Enum.each(rows, fn row -> a.create(resource, Map.from_struct(row), tenant) end)
      :ok
    end

    for row <- post, do: Nexus.Shapes.notify(resource, tenant, :update, row)
    :ok
  end

  @doc """
  Delete rows of `resource` matching `match` (field equality). Uses the backend's native `delete/3`
  when available, else a generic load → clear → recreate-survivors fallback. Emits a `:delete`
  live-shape delta carrying each removed row (subscribers drop it from their local cache). Returns `:ok`.
  """
  def delete(resource, match, tenant \\ @omitted) when is_map(match) do
    a = adapter()
    tenant = resolve_tenant(tenant)
    victims = Enum.filter(a.all(resource, tenant), &matches?(&1, match))

    if function_exported?(a, :delete, 3) do
      a.delete(resource, match, tenant)
    else
      survivors = Enum.reject(a.all(resource, tenant), &matches?(&1, match))
      a.clear(resource, tenant)
      Enum.each(survivors, fn row -> a.create(resource, Map.from_struct(row), tenant) end)
      :ok
    end

    for row <- victims, do: Nexus.Shapes.notify(resource, tenant, :delete, row)
    :ok
  end

  @doc false
  def matches?(row, match), do: Enum.all?(match, fn {k, v} -> Map.get(row, k) == v end)

  @doc "The configured backend (default `Nexus.Store.Ets`)."
  def adapter, do: Application.get_env(:nexus, :store_adapter, Nexus.Store.Ets)

  @doc "The single-tenant / fallback tenant id."
  def default_tenant, do: @default

  # Resolve the tenant arg, FAILING CLOSED on an omitted tenant when the nexus is multi-tenant: a handler
  # that forgets to pass the request's tenant would otherwise read/write the shared "default" partition
  # across tenants (red-team wb-lijn/wb-encp). Single-tenant (multi? == false) keeps the "default" tenant
  # — there it's the one tenant. An EXPLICIT "default" passed by a caller is honored (not omitted).
  defp resolve_tenant(@omitted) do
    if Nexus.Auth.multi?() do
      raise ArgumentError,
            ~S|Nexus.Store call omitted the tenant on a multi-tenant nexus. Pass the request's tenant explicitly (e.g. Store.all(Resource, req.tenant)) — omitting it reads/writes the shared "default" partition across tenants. (wb-lijn)|
    else
      @default
    end
  end

  defp resolve_tenant(tenant), do: tenant
end
