defmodule Workbooks.NexusRegistry do
  @moduledoc """
  The org→nexus registry on the `Workbooks.DB` seam (SQLite by default, Postgres
  when `WB_DATABASE_URL` is set — portable `?1` placeholders throughout). A *nexus*
  is one tenant's deployed compute home: a Fly app + machine + volume + region/plan
  (see `Workbooks.FlyMachines` and the fly bootstrap recipe). This table is the
  control-plane index of which org owns which nexus and its current lifecycle state.

  ISOLATION: `org_id` is the boundary. EVERY read, list, and mutation is scoped
  `WHERE org_id = ?` — `list/1` returns ONLY that org's rows, and
  `get`/`set_state`/`update`/`delete` verify ownership in the same query (an op on a
  nexus the org doesn't own returns `{:error, :not_found}` and NEVER mutates). This
  is the `Tenant.visible?/2` idea pushed all the way into the WHERE clause so the
  rule can't be bypassed by forgetting a post-filter.

  FAIL-CLOSED: a `nil`/empty `org_id` is treated as "no access", not "see all" — it
  matches no row (org_id is never empty for a real caller), so a missing identity
  can neither read nor write another org's nexus.
  """
  alias Workbooks.DB

  @table "nexuses"
  @cols ~w(id org_id name fly_app fly_machine region plan state addons neon_project_id created)

  @doc "Open the store and ensure the table exists (idempotent). Returns a DB handle."
  def open do
    h = DB.open("nexuses")

    DB.execute(h, """
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      org_id TEXT,
      name TEXT,
      fly_app TEXT,
      fly_machine TEXT,
      region TEXT,
      plan TEXT,
      state TEXT,
      addons TEXT,
      neon_project_id TEXT,
      created INTEGER
    )
    """)

    # Migration: a table created before `name` existed gets the column added.
    try do
      DB.execute(h, "ALTER TABLE #{@table} ADD COLUMN name TEXT")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    h
  end

  @doc """
  Register a nexus. `attrs` is a map with at least `:id` and `:org_id` (the owning
  org). A `nil`/empty `org_id` is rejected fail-closed — an unowned nexus would be
  invisible to every scoped query anyway, so we refuse to create one.

  A plain, portable INSERT (no `INSERT OR REPLACE`, which is SQLite-only AND would
  let one org clobber another org's row by colliding the id). If the id already
  exists — under ANY org — `register` returns `{:error, :exists}` and DOES NOT
  modify the existing row. The id is the global PK, so this is the only safe
  cross-backend behaviour (Neon/Postgres has no `OR REPLACE`).
  """
  def register(attrs, h \\ nil) do
    attrs = normalize(attrs)
    org = attrs["org_id"]

    cond do
      blank?(attrs["id"]) -> {:error, :invalid_id}
      blank?(org) -> {:error, :no_org}
      # Strict org_id shape (same rule as NexusProvisioner): a malformed org_id
      # (path-escape, slashes, control/whitespace, over-long) is refused fail-closed
      # so it can never reach a scoped WHERE clause or a storage prefix.
      not valid_org_id?(org) -> {:error, :invalid_org}
      true ->
        h = h || open()

        # Portable existence pre-check: id is the PK, so a hit means the row is
        # already owned (by this org or another) — refuse rather than clobber.
        case DB.query(h, "SELECT id FROM #{@table} WHERE id = ?1", [attrs["id"]]) do
          [_ | _] ->
            {:error, :exists}

          [] ->
            DB.query(
              h,
              "INSERT INTO #{@table} (id, org_id, name, fly_app, fly_machine, region, plan, state, addons, neon_project_id, created) " <>
                "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
              [
                attrs["id"],
                org,
                attrs["name"] || attrs["id"],
                attrs["fly_app"],
                attrs["fly_machine"],
                attrs["region"],
                attrs["plan"],
                attrs["state"] || "created",
                attrs["addons"],
                attrs["neon_project_id"],
                attrs["created"] || System.system_time(:second)
              ]
            )

            {:ok, attrs["id"]}
        end
    end
  end

  @doc "Fetch a nexus by id, SCOPED to `org_id`. Cross-org / unknown → `{:error, :not_found}`."
  def get(id, org_id, h \\ nil) do
    if blank?(org_id) do
      {:error, :not_found}
    else
      h = h || open()

      case DB.query(
             h,
             "SELECT #{Enum.join(@cols, ", ")} FROM #{@table} WHERE id = ?1 AND org_id = ?2",
             [id, org_id]
           ) do
        [row | _] -> {:ok, row_to_map(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "List ONLY `org_id`'s nexuses (newest first). Blank org → `[]` (fail-closed)."
  def list(org_id, h \\ nil) do
    if blank?(org_id) do
      []
    else
      h = h || open()

      DB.query(
        h,
        "SELECT #{Enum.join(@cols, ", ")} FROM #{@table} WHERE org_id = ?1 ORDER BY created DESC",
        [org_id]
      )
      |> Enum.map(&row_to_map/1)
    end
  end

  @doc "Update a nexus's lifecycle state, only if `org_id` owns it. Else `{:error, :not_found}`."
  def set_state(id, org_id, state, h \\ nil), do: update(id, org_id, %{state: state}, h)

  @doc """
  Update a nexus's mutable fields, SCOPED to `org_id`. Only whitelisted columns are
  written; `id`/`org_id`/`created` are immutable. Verifies ownership first so a
  cross-org id never mutates and returns `{:error, :not_found}`.
  """
  def update(id, org_id, attrs, h \\ nil) do
    h = h || open()

    with {:ok, _current} <- get(id, org_id, h) do
      attrs = normalize(attrs) |> Map.take(~w(name fly_app fly_machine region plan state addons neon_project_id))

      if map_size(attrs) == 0 do
        get(id, org_id, h)
      else
        {set_sql, params} =
          attrs
          |> Enum.with_index(1)
          |> Enum.reduce({[], []}, fn {{k, v}, i}, {sets, ps} ->
            {["#{k} = ?#{i}" | sets], [v | ps]}
          end)

        n = length(params)

        DB.query(
          h,
          "UPDATE #{@table} SET #{Enum.join(Enum.reverse(set_sql), ", ")} " <>
            "WHERE id = ?#{n + 1} AND org_id = ?#{n + 2}",
          Enum.reverse(params) ++ [id, org_id]
        )

        get(id, org_id, h)
      end
    end
  end

  @doc "Delete a nexus, only if `org_id` owns it. Returns `:ok` on a confirmed-owned delete, else `{:error, :not_found}`."
  def delete(id, org_id, h \\ nil) do
    h = h || open()

    with {:ok, _} <- get(id, org_id, h) do
      DB.query(h, "DELETE FROM #{@table} WHERE id = ?1 AND org_id = ?2", [id, org_id])
      :ok
    end
  end

  @doc "Does `org_id` own nexus `id`? Reuses the scoped `get/3` — the one ownership rule."
  def owned_by?(id, org_id, h \\ nil) do
    match?({:ok, _}, get(id, org_id, h))
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # Strict org_id shape — the SAME rule as NexusProvisioner.valid_org_id?. Only
  # [a-zA-Z0-9_-], must start alphanumeric, 1..63 chars.
  defp valid_org_id?(s) when is_binary(s),
    do: s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

  defp valid_org_id?(_), do: false

  # Accept atom- or string-keyed attrs; emit string keys for uniform access.
  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp row_to_map(row) when is_list(row) do
    @cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()
  end
end
