defmodule Nexus.Storage do
  @moduledoc """
  Real per-tenant storage metering — the bytes that count toward the storage quota.

  This measures a tenant's **cold-storage footprint** (workspace backups + cold
  cache) on the local tier, under `Nexus.Cache.Cold`'s tenant-scoped path. That's
  the number that counts against the limit when GitHub isn't connected (a connected
  GitHub holds the data in the user's own monorepo, so it doesn't count here).

  Runs **where the data lives** (the tenant's runtime / data volume) — a real `du`,
  not a mock. The control-plane dashboard (`Nexus.Capacity`) consumes a measured
  value via its `:storage_bytes` option; the runtime→control-plane reporting channel
  (and an S3-list sum for the remote tier) layer on top of this primitive.
  """

  @doc "Total cold-storage bytes a tenant uses on the local tier (real, from disk)."
  def cold_bytes(tenant) do
    [Nexus.Config.cache_cold(), "cache", seg(tenant)]
    |> Path.join()
    |> du()
  end

  @doc """
  A storage reading for the dashboard: `%{used_bytes, used_gb, limit_gb, pct, over?}`
  against a tier's `storage_gb` ceiling.
  """
  def report(tenant, limit_gb) when is_integer(limit_gb) do
    used = cold_bytes(tenant)
    used_gb = used / 1_000_000_000
    pct = if limit_gb > 0, do: min(100, round(used_gb / limit_gb * 100)), else: 0
    %{used_bytes: used, used_gb: used_gb, limit_gb: limit_gb, pct: pct, over?: used_gb > limit_gb}
  end

  # Recursive byte sum of a path (file → its size, dir → sum of children, else 0).
  defp du(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        path |> File.ls!() |> Enum.reduce(0, fn e, acc -> acc + du(Path.join(path, e)) end)

      {:ok, %{type: :regular, size: size}} ->
        size

      _ ->
        0
    end
  end

  defp seg(s), do: s |> to_string() |> String.replace(~r{[^A-Za-z0-9_.-]}, "_")
end
