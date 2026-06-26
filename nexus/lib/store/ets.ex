defmodule Nexus.Store.Ets do
  @moduledoc """
  The default `Nexus.Store` backend — an in-memory ETS table per resource, lazily created, **rows
  keyed by tenant** so one tenant never sees another's. Zero deps; perfect for local/dev/tests. The
  Postgres/SQLite/wasm-SQL adapters implement the same callbacks with the same tenant partition.
  """
  @behaviour Nexus.Store

  # rows stored as {auto_id, tenant, struct} in an `ordered_set` keyed by auto_id.

  @impl true
  def create(resource, attrs, tenant) do
    case Nexus.Resource.validate(resource, attrs) do
      {:ok, row} ->
        :ets.insert(table(resource), {System.unique_integer([:monotonic, :positive]), tenant, row})
        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def all(resource, tenant) do
    resource
    |> table()
    |> :ets.match_object({:_, tenant, :_})
    |> Enum.map(fn {_id, _t, row} -> row end)
  end

  @impl true
  def count(resource, tenant), do: :ets.select_count(table(resource), [{{:_, tenant, :_}, [], [true]}])

  # In-memory: there's nothing to push down, so decode-filter-sort-slice the tenant's rows.
  @impl true
  def page(resource, tenant, opts), do: Nexus.Store.Page.apply(all(resource, tenant), opts)

  @impl true
  def clear(resource, tenant) do
    :ets.match_delete(table(resource), {:_, tenant, :_})
    :ok
  end

  # In-place update: re-insert matched rows under the SAME id (preserves insertion order),
  # merging `changes`. Only touches the given tenant's partition.
  @impl true
  def update(resource, match, changes, tenant) do
    t = table(resource)

    t
    |> :ets.match_object({:_, tenant, :_})
    |> Enum.each(fn {id, ten, row} ->
      if Nexus.Store.matches?(row, match), do: :ets.insert(t, {id, ten, struct(row, changes)})
    end)

    :ok
  end

  # Remove the matched rows from the given tenant's partition only.
  @impl true
  def delete(resource, match, tenant) do
    t = table(resource)

    t
    |> :ets.match_object({:_, tenant, :_})
    |> Enum.each(fn {id, _ten, row} ->
      if Nexus.Store.matches?(row, match), do: :ets.delete(t, id)
    end)

    :ok
  end

  defp table(resource) do
    name = Module.concat(resource, "Store")

    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, [:named_table, :public, :ordered_set])
        rescue
          ArgumentError -> name
        end

      _ ->
        name
    end
  end
end
