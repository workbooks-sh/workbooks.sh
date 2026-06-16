defmodule Workbooks.Federation do
  @moduledoc """
  Federation query routing (wb-39j.1) — makes `#+EXEC: federation` functional, not
  just a manifest shape. Two jobs:

    1. DISCOVER data-source plugins from `toolkits/*/plugin/manifest.org`
       (`#+SLOT: data-source`, `#+ENTITIES`, `#+IMPL`) and register each entity →
       its impl module (only if the module exists + implements Workbooks.DataSource;
       fixtures naming a non-existent #+IMPL are skipped, not errors).
    2. ROUTE a query: `SELECT … FROM <entity>` → the plugin if `<entity>` is a
       registered data source, else `:not_federated` (the caller falls through to
       the local VFS — Library.query).

  The credential broker (wb-39j.2), an HTTP/JSON reference plugin (wb-39j.3), and
  the sync daemon (wb-39j.4) build on this core.
  """

  alias Workbooks.DataSource

  @doc """
  Discover + register data-source plugins under `root` (default the toolkits dir).
  Idempotent. Returns the list of {entity, module} registered.
  """
  def discover(root \\ Workbooks.WorkKits.default_root()) do
    Path.wildcard(Path.join(root, "*/plugin/manifest.org"))
    |> Enum.flat_map(fn manifest ->
      d = parse_plugin(File.read!(manifest))

      with "data-source" <- d.slot,
           mod when is_atom(mod) and not is_nil(mod) <- load_impl(d.impl) do
        for entity <- d.entities do
          DataSource.register(entity, mod, d.config)
          {entity, mod}
        end
      else
        _ -> []
      end
    end)
  end

  @doc """
  Route a query. If its `FROM <entity>` names a registered data source, run the
  plugin and return `{:ok, rows} | {:error, _}`. Otherwise `:not_federated`.
  """
  def query(sql, opts \\ []) when is_binary(sql) do
    case from_entity(sql) do
      nil ->
        :not_federated

      entity ->
        case DataSource.lookup(entity) do
          nil -> :not_federated
          module -> module.query(entity, %{sql: sql, config: DataSource.config(entity)}, opts)
        end
    end
  end

  @doc "Is `sql` a federated query (its FROM names a registered data source)?"
  def federated?(sql) when is_binary(sql) do
    case from_entity(sql), do: (nil -> false; e -> DataSource.lookup(e) != nil)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Extract the entity from a `FROM <entity>` clause (entity names allow - and _).
  defp from_entity(sql) do
    case Regex.run(~r/\bFROM\s+([A-Za-z0-9_-]+)/i, sql) do
      [_, entity] -> entity
      _ -> nil
    end
  end

  # Resolve a plugin's #+IMPL string to a loaded module implementing DataSource,
  # or nil (missing module / wrong behaviour / a stale fixture name).
  defp load_impl(nil), do: nil

  defp load_impl(impl) when is_binary(impl) do
    mod = Module.concat([impl])

    if Code.ensure_loaded?(mod) and function_exported?(mod, :query, 3),
      do: mod,
      else: nil
  rescue
    _ -> nil
  end

  # Parse the keywords the data-source face declares. Generic plugins (the HTTP
  # source) read url/rows_path/auth/env_keys from `config`; specialized modules
  # ignore what they don't need.
  defp parse_plugin(org) do
    config =
      %{
        "url" => kw(org, "URL"),
        "rows_path" => kw(org, "ROWS_PATH"),
        "auth" => kw(org, "AUTH"),
        "env_keys" => (kw(org, "ENV_KEYS") || "") |> String.split(~r/\s+/, trim: true)
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, []] end)
      |> Map.new()

    %{
      slot: kw(org, "SLOT"),
      entities: (kw(org, "ENTITIES") || "") |> String.split(~r/\s+/, trim: true),
      impl: kw(org, "IMPL"),
      config: config
    }
  end

  defp kw(org, key) do
    case Regex.run(~r/^\#\+#{key}:\s*(.+?)\s*$/m, org) do
      [_, v] -> v
      _ -> nil
    end
  end
end
