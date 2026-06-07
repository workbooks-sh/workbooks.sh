defmodule Workbooks.Vector do
  @moduledoc """
  Tenant-scoped vector store — the semantic index, on the BYO structured backend
  (`Workbooks.DB`: SQLite default, Postgres when configured). Brute-force cosine
  for now (fine for one library); the interface is stable so a pgvector / sqlite-vec
  ANN adapter drops in later without changing callers (VECTOR-QUERY.org).

  Tenant-scoped exactly like blobs/rows: `tenant` is the first arg of every call,
  so one tenant's vectors are never visible to another. Vectors are stored as JSON
  with their source metadata ({workbook, path, headline, text}) so a hit points
  back to where it came from.
  """
  alias Workbooks.{DB, Embed}

  @doc "Upsert a chunk's vector + source metadata under the tenant scope."
  def upsert(tenant, id, vector, meta \\ %{}) do
    h = open()
    # delete-then-insert = portable upsert (works on SQLite AND Postgres).
    DB.query(h, "DELETE FROM vectors WHERE tenant=?1 AND id=?2", [tenant, id])

    DB.query(
      h,
      "INSERT INTO vectors (tenant, id, workbook, path, headline, vec, text) VALUES (?1,?2,?3,?4,?5,?6,?7)",
      [tenant, id, meta[:workbook] || "", meta[:path] || "", meta[:headline] || "", Jason.encode!(vector), meta[:text] || ""]
    )

    :ok
  end

  @doc """
  Semantic search: top-`k` chunks by cosine to `query_vec`, within the tenant.
  opts: :workbook (one) or :workbooks (a list — a workspace/library scope), :k.
  Returns [%{id, workbook, path, headline, text, score}] (highest score first).
  """
  def search(tenant, query_vec, opts \\ []) do
    h = open()
    k = opts[:k] || 5
    scope = List.wrap(opts[:workbooks] || opts[:workbook])

    rows = DB.query(h, "SELECT id, workbook, path, headline, vec, text FROM vectors WHERE tenant=?1", [tenant])

    rows
    |> Enum.map(fn [id, wb, path, hl, vec, text] ->
      %{id: id, workbook: wb, path: path, headline: hl, text: text, score: Embed.cosine(query_vec, Jason.decode!(vec))}
    end)
    |> then(fn hits -> if scope == [], do: hits, else: Enum.filter(hits, &(&1.workbook in scope)) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(k)
  end

  @doc "Drop a workbook's vectors (re-index / delete)."
  def forget(tenant, workbook) do
    DB.query(open(), "DELETE FROM vectors WHERE tenant=?1 AND workbook=?2", [tenant, workbook])
    :ok
  end

  defp open do
    h = DB.open("vectors")
    DB.execute(h, """
    CREATE TABLE IF NOT EXISTS vectors (
      tenant TEXT, id TEXT, workbook TEXT, path TEXT, headline TEXT, vec TEXT, text TEXT
    )
    """)

    h
  end
end
