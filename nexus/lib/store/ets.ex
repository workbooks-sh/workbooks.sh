defmodule Nexus.Store.Ets do
  @moduledoc """
  The default `Nexus.Store` backend — an in-memory ETS table per resource, lazily created. Zero
  deps, perfect for local/dev/tests. The Postgres/SQLite/wasm-SQL adapters implement the same four
  callbacks; swap `config :nexus, store_adapter:` to move the data, the resource shape unchanged.
  """
  @behaviour Nexus.Store

  @impl true
  def create(resource, attrs) do
    case Nexus.Resource.validate(resource, attrs) do
      {:ok, row} ->
        :ets.insert(table(resource), {System.unique_integer([:monotonic, :positive]), row})
        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def all(resource), do: resource |> table() |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  @impl true
  def count(resource), do: :ets.info(table(resource), :size)

  @impl true
  def clear(resource) do
    :ets.delete_all_objects(table(resource))
    :ok
  end

  # Lazily create the resource's table (named, public, ordered by insertion id).
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
