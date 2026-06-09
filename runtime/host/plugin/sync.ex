defmodule Workbooks.Plugin.Sync do
  @moduledoc """
  The federation SYNC daemon — the 3rd face (wb-39j.4). A supervised GenServer that
  PULLS a data source on an interval and MIRRORS its rows into `:task:`-tagged org
  nodes in the VFS. Unlike the pull-on-demand read face (a query routes live to the
  plugin), this gives a resident, queryable local mirror, airgapped from the agent —
  it only ever writes to the VFS; the agent reads the mirror like any other workbook.

  Driven from a `sync.org` face (`:daemon:` node: `#+ENTITY`, `#+INTERVAL`). The pull
  logic is `pull_once/2` (pure, testable); the GenServer just calls it on a timer.
  """
  use GenServer

  @default_interval_ms 300_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc """
  Pull the registered data source for `entity` once, render its rows as `:task:` org,
  and (if `opts[:vfs]` is given) write it to `opts[:path]` in the VFS. Returns
  `{:ok, count, org}` | `{:error, reason}`. `opts` flow to the data source (e.g.
  `:http` for tests, `:resolver` for auth).
  """
  def pull_once(entity, opts \\ []) do
    case Workbooks.Federation.query("SELECT * FROM #{entity}", opts) do
      {:ok, rows} ->
        org = rows_to_org(entity, rows)
        if vfs = opts[:vfs], do: Workbooks.VFS.put(vfs, opts[:path] || "sync/#{entity}.org", org)
        {:ok, length(rows), org}

      :not_federated ->
        {:error, {:not_a_data_source, entity}}

      {:error, _} = err ->
        err
    end
  end

  # ── server (interval pull) ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    schedule(opts[:interval_ms] || @default_interval_ms)
    {:ok, opts}
  end

  @impl true
  def handle_info(:pull, opts) do
    _ = pull_once(opts[:entity], opts)
    schedule(opts[:interval_ms] || @default_interval_ms)
    {:noreply, opts}
  end

  defp schedule(ms), do: Process.send_after(self(), :pull, ms)

  # ── rendering ────────────────────────────────────────────────────────────────

  # Each row → a `:task:`-tagged headline with its fields as properties. Title is
  # the first of title/name/summary/id; the rest become a :PROPERTIES: drawer.
  defp rows_to_org(entity, rows) do
    header = "#+TITLE: #{entity} (synced)\n#+SYNCED_FROM: #{entity}\n\n"

    body =
      Enum.map_join(rows, "\n\n", fn row ->
        title = row["title"] || row["name"] || row["summary"] || to_string(row["id"] || "item")

        props =
          row
          |> Enum.map_join("\n", fn {k, v} -> ":#{k |> to_string() |> String.upcase()}: #{stringify(v)}" end)

        "* #{title} :task:\n:PROPERTIES:\n#{props}\n:END:"
      end)

    header <> body <> "\n"
  end

  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp stringify(v), do: Jason.encode!(v)
end
