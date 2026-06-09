defmodule Workbooks.DataSource do
  @moduledoc """
  Federation data-source plugin contract (wb-39j.1). A `#+SLOT: data-source` plugin
  registers an entity name; a query `SELECT … FROM <entity>` then routes to its
  `query/3` instead of the local VFS — the OQL read face of a federation toolkit.

  A plugin module implements this behaviour; Workbooks.Federation discovers it from
  the plugin manifest (`#+ENTITIES` → `#+IMPL`) and registers it here. Routing is
  by entity name, in :persistent_term (rare write, fast read), like CommandRegistry.
  """

  @doc """
  Answer a query for `entity`. `q` is the parsed query (today `%{sql: raw}`; a
  plugin parses what it needs). Returns headline-shaped row maps or an error.
  """
  @callback query(entity :: String.t(), q :: map(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @registry {__MODULE__, :sources}

  @doc """
  Register `entity` → a plugin module (implementing this behaviour) with optional
  per-entity `config` (e.g. a generic HTTP source's url/rows_path/env_keys, parsed
  from the plugin manifest). Config reaches the plugin as `q.config`.
  """
  def register(entity, module, config \\ %{}) when is_binary(entity) and is_atom(module) and is_map(config) do
    cur = :persistent_term.get(@registry, %{})
    :persistent_term.put(@registry, Map.put(cur, entity, {module, config}))
    :ok
  end

  @doc "The plugin module registered for `entity`, or nil."
  def lookup(entity) do
    case Map.get(:persistent_term.get(@registry, %{}), entity), do: ({mod, _cfg} -> mod; _ -> nil)
  end

  @doc "The per-entity config registered for `entity` (default %{})."
  def config(entity) do
    case Map.get(:persistent_term.get(@registry, %{}), entity), do: ({_mod, cfg} -> cfg; _ -> %{})
  end

  @doc "All registered entities."
  def entities, do: Map.keys(:persistent_term.get(@registry, %{}))
end
