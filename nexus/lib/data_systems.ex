defmodule Nexus.DataSystems do
  @moduledoc """
  The nexus's DATA SYSTEMS report — *what is stored where*, split by the **durable boundary**
  (`Nexus.Paths`): the persistent volume (`.nexus`) vs the ephemeral deploy root. The cloud dashboard's
  Data page turns this into "here's your volume, and here's every system living on it, hot to cold."

  Sizes are a REAL `du` of each `Nexus.Paths` location for the **self** nexus (the one serving this
  request). A remote tenant nexus reports zeros until its usage channel lands — honest, not fabricated,
  the same discipline as `Nexus.Capacity`.
  """
  alias Nexus.Paths

  @hot_default_mb 64

  @doc "The full data-systems breakdown for the self nexus."
  def report do
    data = Paths.data_dir()
    durable = Paths.durable_dir()
    db = Paths.db_path()

    db_b = file_bytes(db) + file_bytes(db <> "-wal") + file_bytes(db <> "-shm")
    repos_b = du(Paths.repos_root())
    cold_b = du(Paths.cold_dir())
    comps_b = du(Paths.component_cache_dir())
    durable_b = du(durable)
    total_b = du(data)
    ephemeral_b = max(total_b - durable_b, 0)

    hot_mb = Application.get_env(:nexus, :cache_hot_max_mb, @hot_default_mb)

    systems = [
      %{
        key: "database", name: "Database", tier: "durable", ram: false, bytes: db_b, size: human(db_b),
        path: ".nexus/nexus.db",
        role:
          "Accounts, orgs, encrypted secrets, API tokens, sessions, and your resource rows. One SQLite database, replicated off the volume so it survives a machine replacement."
      },
      %{
        key: "repos", name: "Workspace history", tier: "durable", ram: false, bytes: repos_b, size: human(repos_b),
        path: ".nexus/repos",
        role:
          "Git bare repos — the durable source of truth for every pushed workspace and draft, with full version history. Your working copies are re-derived from these."
      },
      %{
        key: "cold_cache", name: "Cold cache", tier: "durable", ram: false, bytes: cold_b, size: human(cold_b),
        path: ".nexus/cache",
        role:
          "The cold tier: entries evicted from hot memory, plus workspace backups. On the volume by default, or off-box when cache-cold points at an s3:// bucket."
      },
      %{
        key: "components", name: "Compiled artifacts", tier: "ephemeral", ram: false, bytes: comps_b, size: human(comps_b),
        path: "build/components",
        role:
          "Compiled wasm artifacts. Deliberately OFF the durable volume — they're rebuilt on demand, so they never cost you persistent storage."
      },
      %{
        key: "checkouts", name: "Workspace checkouts", tier: "ephemeral", ram: false, bytes: max(ephemeral_b - comps_b, 0), size: human(max(ephemeral_b - comps_b, 0)),
        path: "<workspace>/",
        role:
          "Live working copies of your workspaces + the shipped tree. Ephemeral — re-derived from the repos on every boot, so they can be wiped safely."
      },
      %{
        key: "hot_cache", name: "Hot cache", tier: "memory", ram: true, bytes: nil, size: "≤ #{hot_mb} MB",
        path: "memory (ETS)",
        role:
          "A bounded in-memory LRU — the fastest tier. Kept small (a #{hot_mb} MB budget) on purpose so it never competes with your agents for RAM; overflow demotes to the cold cache."
      }
    ]

    %{
      volume: %{
        used_bytes: total_b, used: human(total_b),
        durable_bytes: durable_b, durable: human(durable_b),
        ephemeral_bytes: ephemeral_b, ephemeral: human(ephemeral_b)
      },
      systems: systems
    }
  end

  # ── du (bounded so a pathological tree can't wedge the request) ──────────────────────────────────
  @max_files 200_000
  defp du(path) do
    {bytes, _n} = du(path, 0, 0)
    bytes
  end

  defp du(_path, bytes, n) when n > @max_files, do: {bytes, n}

  defp du(path, bytes, n) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, size: s}} ->
        {bytes + s, n + 1}

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.reduce(entries, {bytes, n + 1}, fn e, {b, c} -> du(Path.join(path, e), b, c) end)

          _ ->
            {bytes, n}
        end

      _ ->
        {bytes, n}
    end
  end

  defp file_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  defp human(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  defp human(b) when b >= 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp human(b) when b >= 1024, do: "#{Float.round(b / 1024, 0) |> trunc()} KB"
  defp human(b), do: "#{b} B"
end
