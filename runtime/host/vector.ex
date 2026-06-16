defmodule Workbooks.Vector do
  @moduledoc """
  Tenant-scoped vector store — the semantic index, on the BYO structured backend
  (`Workbooks.DB`). Backend-aware:

    - SQLite (default): vectors as JSON, brute-force cosine in Elixir — fine for
      one library, zero extension. (sqlite-vec is the ANN upgrade when the
      extension is loadable.)
    - Postgres: a `pgvector` column + ANN in the database (`<=>` cosine distance,
      indexable) — scales to many tenants. The same interface either way, so
      callers never branch.

  Tenant-scoped: `tenant` is the first arg of every call; one tenant's vectors are
  never visible to another. Each row carries source metadata {workbook, path,
  headline, text} so a hit points back. See VECTOR-QUERY.md.
  """
  alias Workbooks.{DB, Embed}

  @doc "Upsert a chunk's vector + source metadata under the tenant scope."
  def upsert(tenant, id, vector, meta \\ %{}) do
    h = open()
    DB.query(h, "DELETE FROM vectors WHERE tenant=?1 AND id=?2", [tenant, id])
    vec = if pg?(), do: vec_literal(vector), else: Jason.encode!(vector)

    DB.query(
      h,
      "INSERT INTO vectors (tenant, id, workbook, path, headline, vec, text) VALUES (?1,?2,?3,?4,?5,?6,?7)",
      [tenant, id, meta[:workbook] || "", meta[:path] || "", meta[:headline] || "", vec, meta[:text] || ""]
    )

    :ok
  end

  @doc """
  Semantic search: top-`k` chunks by cosine to `query_vec`, within the tenant.
  Postgres does the ranking in-DB (ANN); SQLite ranks brute-force. opts:
  :workbook / :workbooks (scope), :k. Returns [%{id, workbook, path, headline,
  text, score}] highest-first.
  """
  def search(tenant, query_vec, opts \\ []) do
    k = opts[:k] || 5
    scope = List.wrap(opts[:workbooks] || opts[:workbook])
    if pg?(), do: pg_search(tenant, query_vec, k, scope), else: sqlite_search(tenant, query_vec, k, scope)
  end

  @doc "Drop a workbook's vectors (re-index / delete)."
  def forget(tenant, workbook) do
    DB.query(open(), "DELETE FROM vectors WHERE tenant=?1 AND workbook=?2", [tenant, workbook])
    :ok
  end

  # ── SQLite path (brute-force cosine, the live-tested default) ─────────────────
  # Brute-force is O(n). A work pool would only buy a constant (cores) factor —
  # the real fix at scale is sub-linear ANN (the pgvector backend, already built).
  # So instead of hiding the linear cost we make it VISIBLE: a one-time warning
  # past a threshold tells the operator to set WB_DATABASE_URL for pgvector ANN.
  @scan_warn 25_000

  defp sqlite_search(tenant, query_vec, k, scope) do
    rows = DB.query(open(), "SELECT id, workbook, path, headline, vec, text FROM vectors WHERE tenant=?1", [tenant])
    warn_if_large(length(rows))

    rows
    |> Enum.map(fn [id, wb, path, hl, vec, text] ->
      %{id: id, workbook: wb, path: path, headline: hl, text: text, score: Embed.cosine(query_vec, Jason.decode!(vec))}
    end)
    |> scope_filter(scope)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  # ── Postgres path (pgvector — ANN in-DB; shape-tested, live step documented) ──
  defp pg_search(tenant, query_vec, k, scope) do
    {clause, params} =
      if scope == [],
        do: {"", []},
        else: {" AND workbook = ANY(?2)", [scope]}

    qparam = if scope == [], do: 2, else: 3

    sql =
      "SELECT id, workbook, path, headline, 1 - (vec <=> ?#{qparam}::vector) AS score, text " <>
        "FROM vectors WHERE tenant=?1#{clause} ORDER BY vec <=> ?#{qparam}::vector LIMIT #{k}"

    DB.query(open(), sql, [tenant] ++ params ++ [vec_literal(query_vec)])
    |> Enum.map(fn [id, wb, path, hl, score, text] ->
      %{id: id, workbook: wb, path: path, headline: hl, text: text, score: score}
    end)
  end

  defp scope_filter(hits, []), do: hits
  defp scope_filter(hits, scope), do: Enum.filter(hits, &(&1.workbook in scope))

  defp warn_if_large(n) when n > @scan_warn do
    unless :persistent_term.get({__MODULE__, :warned}, false) do
      require Logger
      Logger.warning(
        "Vector: brute-force search over #{n} vectors on SQLite (O(n) per query). " <>
          "For sub-linear ANN at scale, set WB_DATABASE_URL → pgvector. See docs/VECTOR-QUERY.md."
      )

      :persistent_term.put({__MODULE__, :warned}, true)
    end

    :ok
  end

  defp warn_if_large(_), do: :ok

  # pgvector literal: "[0.1,0.2,…]" (cast `::vector` in the query).
  @doc false
  def vec_literal(vector), do: "[" <> Enum.map_join(vector, ",", &to_string/1) <> "]"

  defp pg?, do: DB.backend() == :postgres

  defp open do
    h = DB.open("vectors")

    ddl =
      if pg?() do
        DB.execute(h, "CREATE EXTENSION IF NOT EXISTS vector")
        "CREATE TABLE IF NOT EXISTS vectors (tenant TEXT, id TEXT, workbook TEXT, path TEXT, headline TEXT, vec vector(#{Embed.dim()}), text TEXT)"
      else
        "CREATE TABLE IF NOT EXISTS vectors (tenant TEXT, id TEXT, workbook TEXT, path TEXT, headline TEXT, vec TEXT, text TEXT)"
      end

    DB.execute(h, ddl)
    h
  end
end
