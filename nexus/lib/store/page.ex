defmodule Nexus.Store.Page do
  @moduledoc """
  Shared pagination/filter/sort over a list of resource structs — the in-memory slicer every
  `Nexus.Store` backend falls back to. Rows are term blobs (no SQL columns to push down to), so
  filtering and field-sorting happen on the *decoded* structs. A backend may short-circuit the
  default browse case (no filter, insertion-order sort) with native `LIMIT/OFFSET` — see
  `Nexus.Store.Sqlite.page/3` — but the contract and result shape live here.

  Returns `{page_rows, total}` where `total` is the count AFTER filtering (so the UI can show
  "showing 50 of <total matches>"), never the page length.
  """

  @default_limit 50
  @max_limit 500

  @typedoc "offset (>=0), limit (1..500), sort ({field, :asc|:desc} | nil), q (search string | nil)"
  @type opts :: keyword

  @doc "Normalize raw opts (keyword/strings from a request) into a clamped struct-ish map."
  def opts(o) do
    %{
      offset: max(int(o[:offset], 0), 0),
      limit: o[:limit] |> int(@default_limit) |> max(1) |> min(@max_limit),
      sort: norm_sort(o[:sort]),
      q: norm_q(o[:q])
    }
  end

  @doc "Filter → sort → slice a decoded row list. Returns `{page_rows, total_after_filter}`."
  def apply(rows, raw_opts) do
    o = opts(raw_opts)
    filtered = if o.q, do: Enum.filter(rows, &matches?(&1, o.q)), else: rows
    total = length(filtered)
    page = filtered |> sort(o.sort) |> Enum.slice(o.offset, o.limit)
    {page, total}
  end

  @doc "True when a backend can serve this page with plain insertion-order `LIMIT/OFFSET`."
  def native_ok?(o), do: is_nil(o.q) and o.sort in [nil, {nil, :asc}]

  # --- internals ---

  defp matches?(%_{} = struct, q) do
    struct
    |> Map.from_struct()
    |> Enum.any?(fn {_k, v} -> v |> stringify() |> String.downcase() |> String.contains?(q) end)
  end

  defp matches?(_, _), do: false

  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_nil(v), do: ""
  defp stringify(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp stringify(v), do: inspect(v)

  defp sort(rows, nil), do: rows
  defp sort(rows, {nil, _}), do: rows

  defp sort(rows, {field, dir}) when is_atom(field) do
    # nil values always TRAIL, in both directions (a "sort by score" shouldn't float blanks to the
    # top under :desc just because nil outranks numbers in Erlang term order).
    {nils, vals} = Enum.split_with(rows, &is_nil(Map.get(&1, field)))
    cmp = if dir == :desc, do: &>=/2, else: &<=/2
    Enum.sort_by(vals, &Map.get(&1, field), cmp) ++ nils
  end

  defp norm_sort(nil), do: nil
  defp norm_sort({f, d}) when d in [:asc, :desc], do: {safe_field(f), d}
  defp norm_sort({f, d}) when is_binary(d), do: norm_sort({f, dir(d)})
  defp norm_sort(f) when is_binary(f) or is_atom(f), do: {safe_field(f), :asc}
  defp norm_sort(_), do: nil

  defp dir("desc"), do: :desc
  defp dir(_), do: :asc

  # Only resolve to an EXISTING atom — a request can't conjure arbitrary atoms (avoids atom-table
  # exhaustion), and a non-field sort silently degrades to insertion order rather than crashing.
  defp safe_field(f) when is_atom(f), do: f

  defp safe_field(f) when is_binary(f) do
    String.to_existing_atom(f)
  rescue
    ArgumentError -> nil
  end

  defp norm_q(nil), do: nil
  defp norm_q(""), do: nil
  defp norm_q(s) when is_binary(s), do: s |> String.trim() |> downcase_or_nil()
  defp norm_q(_), do: nil

  defp downcase_or_nil(""), do: nil
  defp downcase_or_nil(s), do: String.downcase(s)

  defp int(nil, d), do: d
  defp int(i, _) when is_integer(i), do: i

  defp int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      _ -> d
    end
  end

  defp int(_, d), do: d
end
