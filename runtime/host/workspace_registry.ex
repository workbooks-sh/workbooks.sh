defmodule Workbooks.WorkspaceRegistry do
  @moduledoc """
  The org→workspace registry on the `Workbooks.DB` seam (SQLite by default, Postgres
  when `WB_DATABASE_URL` is set). A *workspace* is a FREE, named division within an
  org — projects/teams/apps. It costs nothing to create (no Fly machine): it's a
  logical partition that runs on a nexus (`nexus_id`, defaulting to the org's primary
  nexus). Multiple nexuses exist only when an org wants hard compute isolation for
  some workspaces; by default many free workspaces share one nexus.

  ISOLATION: `org_id` is the boundary. EVERY read/list/mutation is scoped
  `WHERE org_id = ?`, so an org only ever sees or touches its own workspaces; a
  cross-org id returns `{:error, :not_found}` and never mutates.

  IDs are random (`ws-…`), never a slug of the name — so two orgs can both have a
  "Marketing" workspace without colliding on the global PK, and a name is purely a
  display label (free to duplicate / rename).
  """
  alias Workbooks.DB

  @table "workspaces"
  @cols ~w(id org_id name nexus_id created)

  @doc "Open the store and ensure the table exists (idempotent). Returns a DB handle."
  def open do
    h = DB.open("workspaces")

    DB.execute(h, """
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      org_id TEXT,
      name TEXT,
      nexus_id TEXT,
      created INTEGER
    )
    """)

    h
  end

  @doc """
  Create a FREE workspace for `org_id`. Generates a non-guessable id and inserts the
  row. `opts[:nexus_id]` pins the compute it runs on (default `nil` = the org's
  primary nexus, resolved at run time). Returns `{:ok, workspace}` or a fail-closed
  `{:error, _}` for a blank/malformed org or an empty name.
  """
  def create(org_id, name, opts \\ [], h \\ nil) do
    name = clean_name(name)

    cond do
      blank?(org_id) -> {:error, :no_org}
      not valid_org_id?(org_id) -> {:error, :invalid_org}
      name == "" -> {:error, :invalid_name}
      true ->
        h = h || open()
        id = "ws-" <> rand_token(8)
        created = System.system_time(:second)
        nexus_id = opts[:nexus_id]

        DB.query(
          h,
          "INSERT INTO #{@table} (id, org_id, name, nexus_id, created) VALUES (?1, ?2, ?3, ?4, ?5)",
          [id, org_id, name, nexus_id, created]
        )

        {:ok, %{id: id, org_id: org_id, name: name, nexus_id: nexus_id, created: created}}
    end
  end

  @doc "List ONLY `org_id`'s workspaces (oldest first — first created stays on top). Blank org → `[]`."
  def list(org_id, h \\ nil) do
    if blank?(org_id) do
      []
    else
      h = h || open()

      DB.query(
        h,
        "SELECT #{Enum.join(@cols, ", ")} FROM #{@table} WHERE org_id = ?1 ORDER BY created ASC",
        [org_id]
      )
      |> Enum.map(&row_to_map/1)
    end
  end

  @doc "Fetch a workspace by id, SCOPED to `org_id`. Cross-org / unknown → `{:error, :not_found}`."
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

  @doc "Rename a workspace, only if `org_id` owns it. Else `{:error, :not_found}`."
  def rename(id, org_id, name, h \\ nil) do
    name = clean_name(name)
    h = h || open()

    cond do
      name == "" -> {:error, :invalid_name}
      true ->
        with {:ok, _} <- get(id, org_id, h) do
          DB.query(h, "UPDATE #{@table} SET name = ?1 WHERE id = ?2 AND org_id = ?3", [name, id, org_id])
          get(id, org_id, h)
        end
    end
  end

  @doc "Delete a workspace, only if `org_id` owns it. `:ok` on a confirmed-owned delete, else `{:error, :not_found}`."
  def delete(id, org_id, h \\ nil) do
    h = h || open()

    with {:ok, _} <- get(id, org_id, h) do
      DB.query(h, "DELETE FROM #{@table} WHERE id = ?1 AND org_id = ?2", [id, org_id])
      :ok
    end
  end

  @doc """
  Ensure `org_id` has at least one workspace — returns the existing list, or creates
  one named `default_name` and returns `[it]`. Used at onboarding/first-load so a
  signed-in org always lands in a real workspace.
  """
  def ensure(org_id, default_name, h \\ nil) do
    h = h || open()

    case list(org_id, h) do
      [] ->
        case create(org_id, default_name, [], h) do
          {:ok, ws} -> [ws]
          _ -> []
        end

      existing ->
        existing
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────

  # A display name: trimmed, control-chars stripped, capped. May contain spaces/unicode.
  defp clean_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[\x00-\x1f\x7f]/, "")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp rand_token(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp valid_org_id?(s) when is_binary(s), do: s =~ ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/
  defp valid_org_id?(_), do: false

  defp row_to_map(row) when is_list(row) do
    @cols |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()
  end
end
