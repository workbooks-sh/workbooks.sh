defmodule Nexus.Schema do
  @moduledoc """
  §10 (data reality) — introspect what a `resource` actually looks like in its live
  store, versus what it *declared* (`Nexus.Resource` `__fields__`). The graph carries
  the declared shape; this reads the backend's reality and, where the backend is
  columnar, diffs the two for schema drift — the same declared-vs-reality pattern
  the artifact facet (§3) uses for compiled wasm.

  Each backend exposes a different depth of reality, so the facet is honest about it:

    * `:memory` (ETS) — the declared struct *is* the shape; rows + backend only.
    * `:blob`   (SQLite term-blob) — durable, faithfully stores the declared shape;
      rows + table, no field-level columns to drift against.
    * `:columnar` (Postgres/Neon — the cloud data tier) — real columns from
      `information_schema`; drift lights up here (a declared field absent from the
      table, or an undeclared column). The backend supplies them via the optional
      `Nexus.Store` `columns/2` callback.

  Projected into a `Nexus.Overlay` via `overlay/2` and joined onto the pure graph by
  `Nexus.Graph.with_overlay/2`. No new authoring syntax — the schema is read back,
  never written.
  """

  alias Nexus.{Store, Overlay, Uid}

  @doc """
  The live data facet for one compiled resource module: backend, storage mode, table,
  row count, the declared field shape, and (columnar only) real columns + drift.
  """
  def of(module, tenant \\ Store.default_tenant()) when is_atom(module) do
    backend = Store.adapter()
    {storage, table, columns} = introspect(backend, module, tenant)
    declared = declared_fields(module)

    %{
      backend: backend,
      storage: storage,
      table: table,
      rows: safe_count(module, tenant),
      declared: declared,
      columns: columns,
      drift: if(storage == :columnar and columns, do: diff(declared, columns), else: nil)
    }
  end

  @doc """
  Diff declared field names against actual columns (columnar backends). `missing` =
  declared but absent from the table; `extra` = a column with no declared field.
  """
  def diff(declared, columns) do
    dnames = declared |> Enum.map(fn {n, _t} -> to_string(n) end)
    cnames = Enum.map(columns, &to_string/1)

    res = %{missing: dnames -- cnames, extra: cnames -- dnames}
    Map.put(res, :ok?, res.missing == [] and res.extra == [])
  end

  @doc """
  Project a reality overlay for the given resources — `[{unit_name, module}]` —
  keyed by canonical Uid so `Graph.with_overlay/2` fills each node's `facets.data`.
  """
  def overlay(resources, tenant \\ Store.default_tenant()) do
    Enum.reduce(resources, Overlay.new(), fn {name, module}, ov ->
      Overlay.put_data(ov, Uid.key(name), of(module, tenant))
    end)
  end

  # ── per-backend introspection ── {storage_mode, table | nil, columns | nil}

  defp introspect(Nexus.Store.Ets, _module, _tenant), do: {:memory, nil, nil}

  defp introspect(Nexus.Store.Sqlite, module, _tenant) do
    {:blob, sqlite_table(module), nil}
  end

  # a columnar backend (Postgres/Neon) exposes real columns via the Store `columns/2`
  # callback (information_schema). That's what makes data drift meaningful — the live
  # table is diffed against the declared shape.
  defp introspect(backend, module, tenant) do
    cols =
      if function_exported?(backend, :columns, 2),
        do: backend.columns(module, tenant),
        else: nil

    {:columnar, nil, cols}
  end

  defp sqlite_table(module), do: "r_" <> (module |> Module.split() |> Enum.join("_") |> String.downcase())

  defp declared_fields(module) do
    if function_exported?(module, :__fields__, 0), do: module.__fields__(), else: []
  end

  defp safe_count(module, tenant) do
    Store.count(module, tenant)
  rescue
    _ -> 0
  end
end
