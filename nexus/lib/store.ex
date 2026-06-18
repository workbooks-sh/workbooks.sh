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

  @default "default"

  @doc "Validate `attrs` against the resource's shape and persist a row for `tenant`."
  def create(resource, attrs, tenant \\ @default), do: adapter().create(resource, attrs, tenant)

  @doc "All rows of a resource visible to `tenant`."
  def all(resource, tenant \\ @default), do: adapter().all(resource, tenant)

  @doc "How many rows a resource has for `tenant`."
  def count(resource, tenant \\ @default), do: adapter().count(resource, tenant)

  @doc "Drop a resource's rows for `tenant` (never touches other tenants)."
  def clear(resource, tenant \\ @default), do: adapter().clear(resource, tenant)

  @doc "The configured backend (default `Nexus.Store.Ets`)."
  def adapter, do: Application.get_env(:nexus, :store_adapter, Nexus.Store.Ets)

  @doc "The single-tenant / fallback tenant id."
  def default_tenant, do: @default
end
