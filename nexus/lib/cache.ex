defmodule Nexus.Cache do
  @moduledoc """
  The **tenant-aware, two-tier cache** seam — the real, tiered, tenant-scoped version of the toy kv
  the Dock exposes (`store`/`load` over `:persistent_term`). Mirrors `Nexus.Store`: a behaviour whose
  every callback takes a `tenant`, and one tenant can never read another's keys — isolation is
  enforced HERE, in the seam, not hoped for upstream.

  Two tiers (default provider `Nexus.Cache.Tiered`):

    * **hot** — a bounded ETS table owned by a supervised GenServer, LRU-evicted at a *byte* budget
      (`cache-hot-max-mb`, default 64). Deliberately small so on a 1GB host it never competes with
      agents for RAM.
    * **cold** — `Nexus.Cache.Cold`, a seam that abstracts over the deploy target: the local
      data-volume route (`Local`, default) or the egress-free R2 object store (`R2`, cloud), picked
      from the `cache-cold` config the way the compile store switches on `component-cache`. On
      hot-evict of a still-live entry it is **demoted** to cold; on a hot miss the cold tier is
      checked and a live entry **promoted** back into hot.

  Every key is `{tenant, namespace, key}`. The cold object path embeds the tenant. No global keys.

  ## WIT interface (Dock capability)

  The cache surface is expressible as a WIT `interface cache`, consistent with how `Nexus.Wit`
  projects host capabilities, so a wasm guest can reach it through `Nexus.Dock` exactly like `store`/
  `load`. See `wit/0`:

      interface cache {
        get: func(key: string) -> option<list<u8>>;
        put: func(key: string, val: list<u8>, ttl: u32);
        delete: func(key: string);
      }

  (The guest-facing surface is `{namespace, key}` flattened to one `key` string; `tenant` is bound by
  the host from `Nexus.Auth`, never passed by the guest — a guest cannot name another tenant.)
  """

  @type tenant :: String.t()
  @type namespace :: String.t()
  @type key :: String.t()
  @type value :: binary
  @type opts :: [ttl: pos_integer | :infinity]

  @callback get(tenant, namespace, key) :: {:ok, value} | :miss
  @callback put(tenant, namespace, key, value, opts) :: :ok
  @callback delete(tenant, namespace, key) :: :ok

  @default "default"

  @doc "The configured provider (default `Nexus.Cache.Tiered`)."
  def provider, do: Application.get_env(:nexus, :cache_provider, Nexus.Cache.Tiered)

  @doc "Child specs for the cache's hot-tier owner process (started in `Nexus.Application`)."
  def child_specs, do: [Nexus.Cache.Tiered]

  @doc "Read `key` in `tenant`/`namespace`. `{:ok, value}` on a hot OR (promoted) cold hit; `:miss`."
  def get(tenant \\ @default, namespace, key), do: provider().get(tenant, namespace, key)

  @doc """
  Write `value`. `opts[:ttl]` = shelf-life in seconds (default `cache-default-ttl`); `:infinity` to
  never expire.
  """
  def put(tenant \\ @default, namespace, key, value, opts \\ []),
    do: provider().put(tenant, namespace, key, value, opts)

  @doc "Drop `key` from both tiers for `tenant` (never touches another tenant)."
  def delete(tenant \\ @default, namespace, key), do: provider().delete(tenant, namespace, key)

  @doc """
  Read-through: return the cached value, or run `fun` on a miss, cache its result, and return it.
  `opts` are passed to `put/5` on the miss path.
  """
  def fetch(tenant \\ @default, namespace, key, fun, opts \\ []) when is_function(fun, 0) do
    case get(tenant, namespace, key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(tenant, namespace, key, value, opts)
        value
    end
  end

  @doc "The single-tenant / fallback tenant id."
  def default_tenant, do: @default

  @doc """
  The WIT `interface cache` this seam projects — a Dock capability typed like the rest of
  `Nexus.Wit`'s host interfaces, so a wasm guest can `import cache` and call get/put/delete.
  """
  def wit do
    """
    interface cache {
      get: func(key: string) -> option<list<u8>>;
      put: func(key: string, val: list<u8>, ttl: u32);
      delete: func(key: string);
    }
    """
  end
end
