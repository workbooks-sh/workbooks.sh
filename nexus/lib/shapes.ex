defmodule Nexus.Shapes do
  @moduledoc """
  **Live-shapes** — the generic real-time data layer (open standard, generic mechanism only).

  A *shape* is a subscription to `(resource + tenant + filter)`. A client renders from its local
  cache; the server pushes **resource deltas** (`:insert` / `:update` / `:delete`) to every live
  subscriber whose shape matches — so the live queries the UI already assumes are actually live,
  without per-view polling. This is the substrate `Nexus.Ws` exposes to browsers (the
  `{"op":"subscribe","shape":…}` frame) and the runtime consumes internally.

  Flow:

      Nexus.Store.create/update  ──▶  Nexus.Shapes.notify(resource, tenant, op, row)
                                         └─▶ for each subscriber of {tenant, resource}
                                               whose filter passes  ──▶ send {:shape_delta, delta}

  **Access is checked BEFORE fan-out, two ways that compose:**

    1. **Tenant partition** — a shape is keyed by `{tenant, resource}`. A delta only reaches
       subscribers registered under the SAME tenant. Cross-tenant fan-out is structurally
       impossible (mirrors `Nexus.Store`'s tenant partitioning — never hoped for upstream).
    2. **Filter predicate** — the subscriber's `filter` (a `row -> bool`, e.g. a workspace/channel
       equality check) runs against the row; a delta the subscriber can't see never leaves the
       server. The `Nexus.Ws` subscribe path derives this from the socket's server-side identity,
       never from client-supplied params alone.

  Ephemeral by design: subscriptions live in a `Registry` (a subscriber that dies is auto-removed),
  never in `.work` and never in the store. `notify/4` is a cheap no-op when nobody is watching that
  `{tenant, resource}`, so the write path pays ~nothing until a shape is actually open.
  """

  @reg Nexus.Shapes.Registry

  @type op :: :insert | :update | :delete
  @type delta :: %{resource: module, tenant: String.t(), op: op, row: term}

  @doc "Child specs for the supervision tree — a duplicate-key Registry of live subscriptions."
  def child_specs, do: [{Registry, keys: :duplicate, name: @reg}]

  # ── subscribable-shape allowlist ────────────────────────────────────────────────────────────────
  # A browser names a shape by STRING over the wire. We never `String.to_atom` untrusted input (atom
  # exhaustion / arbitrary-module reach). Instead a product registers, by name, exactly which resources
  # are client-subscribable and which field scopes them (e.g. "messages" → {Message, :channel}). The WS
  # layer resolves only against this allowlist; an unknown name is rejected, never coerced to a module.
  @registry {__MODULE__, :registered}

  @doc """
  Register a client-subscribable shape: `name` (the wire string) → `resource` module, scoped by
  `scope_field` (the field a `scope` param filters on, or `nil` for a whole-tenant shape). Idempotent.
  """
  @spec register(String.t(), module, atom | nil) :: :ok
  def register(name, resource, scope_field \\ nil)
      when is_binary(name) and is_atom(resource) and (is_atom(scope_field) or is_nil(scope_field)) do
    :persistent_term.put(@registry, Map.put(registered(), name, {resource, scope_field}))
    :ok
  end

  @doc "Resolve a wire name to `{resource, scope_field}` from the allowlist, or `:error` if unknown."
  @spec resolve(String.t()) :: {module, atom | nil} | :error
  def resolve(name) when is_binary(name), do: Map.get(registered(), name, :error)

  defp registered, do: :persistent_term.get(@registry, %{})

  @doc """
  Subscribe the calling process to a shape: deltas for `resource` in `tenant` whose `filter`
  passes are delivered as `{:shape_delta, delta}` messages. `filter` defaults to "all rows in the
  tenant". Returns `:ok`. The subscription is dropped automatically when the caller dies.
  """
  @spec subscribe(module, String.t(), (term -> boolean)) :: :ok
  def subscribe(resource, tenant, filter \\ fn _ -> true end)
      when is_atom(resource) and is_binary(tenant) and is_function(filter, 1) do
    {:ok, _} = Registry.register(@reg, {tenant, resource}, filter)
    :ok
  end

  @doc "Drop the caller's subscriptions to `{tenant, resource}` (all processes leaving still auto-clean)."
  @spec unsubscribe(module, String.t()) :: :ok
  def unsubscribe(resource, tenant) when is_atom(resource) and is_binary(tenant) do
    Registry.unregister(@reg, {tenant, resource})
    :ok
  end

  @doc """
  Notify live subscribers of a delta. Called by `Nexus.Store` on a successful write. A cheap no-op
  when nobody is watching `{tenant, resource}`. Each subscriber's `filter` runs (fail-closed: a
  filter that raises drops the delta for that subscriber) before the message is sent. Always
  returns `:ok` — the write path must never fail because the live layer is unhappy.
  """
  @spec notify(module, String.t(), op, term) :: :ok
  def notify(resource, tenant, op, row)
      when is_atom(resource) and is_binary(tenant) and op in [:insert, :update, :delete] do
    delta = %{resource: resource, tenant: tenant, op: op, row: row}

    Registry.dispatch(@reg, {tenant, resource}, fn entries ->
      for {pid, filter} <- entries do
        deliver? =
          try do
            filter.(row)
          rescue
            _ -> false
          end

        if deliver?, do: send(pid, {:shape_delta, delta})
      end
    end)

    :ok
  rescue
    # Registry not started (e.g. a pure-pipeline mix task, not a serving tree) — the write still stands.
    _ -> :ok
  end

  @doc """
  The initial snapshot for a freshly-opened shape: the current rows of `resource` in `tenant` that
  pass `filter`. A subscriber renders this once, then applies deltas. Read straight from the store,
  so a subscriber that opens, snapshots, then streams never misses a write (the snapshot + the live
  feed are both tenant-partitioned and filter-checked the same way).
  """
  @spec snapshot(module, String.t(), (term -> boolean)) :: [term]
  def snapshot(resource, tenant, filter \\ fn _ -> true end)
      when is_atom(resource) and is_binary(tenant) and is_function(filter, 1) do
    resource |> Nexus.Store.all(tenant) |> Enum.filter(filter)
  end
end
