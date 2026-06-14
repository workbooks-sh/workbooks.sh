defmodule Workbooks.UsageMeter do
  @moduledoc """
  Per-org usage accounting on the `Workbooks.DB` seam — the billing ledger. Each
  metered event (a chunk of compute time, stored bytes, or db time) is an append-only
  row; `usage/2` aggregates an org's events into per-type totals for billing.

  ISOLATION: `org_id` is the boundary. `record` requires a non-blank `org_id`
  (fails closed otherwise), and `usage` aggregates `WHERE org_id = ?1` so an org's
  totals NEVER include another org's events. A `nil`/empty `org_id` on `usage`
  returns empty totals — "no identity" sees nothing, not everything.

  Portable SQL (`?1` placeholders) so it runs unchanged on SQLite (default) and
  Postgres (`WB_DATABASE_URL`).
  """
  alias Workbooks.DB

  @table "usage_events"
  @types ~w(compute_seconds storage_bytes db_seconds)

  @doc "Open the store and ensure the table exists (idempotent). Returns a DB handle."
  def open do
    h = DB.open("usage")

    DB.execute(h, """
    CREATE TABLE IF NOT EXISTS #{@table} (
      org_id TEXT NOT NULL,
      nexus_id TEXT,
      type TEXT NOT NULL,
      amount REAL NOT NULL,
      at INTEGER NOT NULL
    )
    """)

    h
  end

  @doc """
  Record one usage event for `org_id` on `nexus_id`. `type` must be one of
  `compute_seconds | storage_bytes | db_seconds`; `amount` a NON-NEGATIVE number.
  Returns `{:ok, amount}` on a confirmed write; fails closed (`{:error, _}`) on a
  blank `org_id`, an unknown `type`, a negative/non-numeric `amount`, or a DB write
  failure.
  """
  def record(org_id, nexus_id, type, amount, h \\ nil) do
    type = to_string(type)

    cond do
      blank?(org_id) -> {:error, :no_org}
      type not in @types -> {:error, :invalid_type}
      # A negative amount would silently corrupt billing totals (SUM). Only a
      # finite, non-negative number is a valid metered amount.
      not (is_number(amount) and amount >= 0) -> {:error, :invalid_amount}
      true ->
        h = h || open()

        # DB.query raises (Postgrex.query! / Sqlite3 :error) on a write failure.
        # Fail CLOSED: surface {:error, _} rather than reporting a billing write
        # that never landed as success.
        try do
          DB.query(
            h,
            "INSERT INTO #{@table} (org_id, nexus_id, type, amount, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            [org_id, nexus_id, type, amount * 1.0, System.system_time(:second)]
          )

          {:ok, amount * 1.0}
        rescue
          e -> {:error, e}
        end
    end
  end

  @doc """
  Aggregate `org_id`'s usage since `since` (a unix-second epoch, default 0 = all
  time) into a `%{type => total}` map. SCOPED to `org_id` — another org's events are
  never counted. A blank `org_id` returns `%{}` (fail-closed).
  """
  def usage(org_id, since \\ 0, h \\ nil) do
    if blank?(org_id) do
      %{}
    else
      h = h || open()

      DB.query(
        h,
        "SELECT type, SUM(amount) FROM #{@table} WHERE org_id = ?1 AND at >= ?2 GROUP BY type",
        [org_id, since]
      )
      |> Enum.into(%{}, fn [type, total] -> {type, num(total)} end)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────

  defp num(nil), do: 0.0
  defp num(n) when is_number(n), do: n * 1.0
  # Postgres may hand back a Decimal for SUM; coerce to float without a compile-time
  # dep on the Decimal module.
  defp num(%{__struct__: Decimal} = d), do: Decimal.to_float(d)
  defp num(n), do: n

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
