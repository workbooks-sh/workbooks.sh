defmodule Nexus.Store do
  @moduledoc """
  The **universal persistence adapter** — the seam behind the typed-struct base (`Nexus.Resource`).
  A `resource` compiles to a plain struct (the shape, client + server, no deps); *where* its rows
  live is a swappable backend behind this one interface:

    * **default** — `Nexus.Store.Ets`, in-memory, zero deps (great for local/dev/tests)
    * **cloud** — Neon Postgres (the hosted target)
    * **local** — self-hosted Postgres / SQLite / a wasm-SQL engine (WQL) — undecided, and that's
      fine: the interface doesn't care. The struct is the Elixir representation every backend
      fields into.

  Configure with `config :nexus, store_adapter: SomeAdapter` (defaults to ETS). Adapters implement
  these four callbacks.
  """

  @callback create(resource :: module, attrs :: map) :: {:ok, struct} | {:error, term}
  @callback all(resource :: module) :: [struct]
  @callback count(resource :: module) :: non_neg_integer
  @callback clear(resource :: module) :: :ok

  @doc "Validate `attrs` against the resource's shape and persist a row."
  def create(resource, attrs), do: adapter().create(resource, attrs)

  @doc "All rows of a resource."
  def all(resource), do: adapter().all(resource)

  @doc "How many rows a resource has."
  def count(resource), do: adapter().count(resource)

  @doc "Drop all rows of a resource."
  def clear(resource), do: adapter().clear(resource)

  @doc "The configured backend (default `Nexus.Store.Ets`)."
  def adapter, do: Application.get_env(:nexus, :store_adapter, Nexus.Store.Ets)
end
