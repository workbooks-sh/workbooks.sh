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

  @doc "Register `entity` → a plugin module implementing this behaviour."
  def register(entity, module) when is_binary(entity) and is_atom(module) do
    cur = :persistent_term.get(@registry, %{})
    :persistent_term.put(@registry, Map.put(cur, entity, module))
    :ok
  end

  @doc "The plugin module registered for `entity`, or nil."
  def lookup(entity), do: Map.get(:persistent_term.get(@registry, %{}), entity)

  @doc "All registered entities."
  def entities, do: Map.keys(:persistent_term.get(@registry, %{}))
end
