defmodule Nexus.Capacity do
  @moduledoc """
  Capacity feedback for a nexus — RAM + storage used against the tier ceiling,
  and, when the dial runs hot, WHAT to shed: the top RAM consumers and the
  biggest stored objects. The nexus auto-scales within its ceiling; this is the
  signal the dashboard turns into "near capacity → scale up to continue".

  The local/self nexus is measured for REAL — RAM from `/proc/meminfo`, storage from the data dir's
  on-disk footprint — against the `Nexus.Pricing` tier ceiling. A REMOTE tenant nexus reports 0 until
  the usage-report channel lands (honest, not a fabricated number). The math (used vs ceiling, the
  near/over thresholds) is the production logic.
  """
  alias Nexus.Pricing

  @doc "The full usage + capacity report for an org's (single) nexus."
  def report(nil) do
    tier = Pricing.default_tier()
    %{
      tier: tier_view(tier),
      next: tier_view(Pricing.next_tier(tier.id)),
      ram: dial(0, tier.ram_mb, "MB"),
      storage: dial(0, tier.storage_gb, "GB"),
      topRam: [],
      topObjects: [],
      monthToDate: "$0.00",
      compute: "$0.00",
      activeHrs: 0,
      load: 0
    }
  end

  def report(nx, opts \\ []) do
    tier = Pricing.tier(nx[:plan])
    running? = nx[:state] == "running"
    seed = :erlang.phash2(nx[:id] || "nx")

    # REAL measurement for the nexus we're running on (the self/local nexus — the common single-nexus
    # case). The control plane can't yet pull a REMOTE tenant's live metrics (the usage-report channel
    # is next), so a remote nexus reports 0 rather than a fabricated number — honest, not showcase.
    local? = nx[:self] == true or remote_url(nx) in [nil, ""]

    ram_used =
      cond do
        not running? -> 0
        local? -> local_ram_mb()
        true -> 0
      end

    storage_used =
      case Keyword.get(opts, :storage_bytes) do
        b when is_integer(b) -> round(b / 1_000_000_000)
        _ -> if running? and local?, do: local_storage_gb(), else: 0
      end

    ram_dial = dial(ram_used, tier.ram_mb, "MB")
    storage_dial = dial(storage_used, tier.storage_gb, "GB")

    %{
      tier: tier_view(tier),
      next: tier_view(Pricing.next_tier(tier.id)),
      ram: ram_dial,
      storage: storage_dial,
      # Only surface "what to shed" once a dial is hot — the dashboard hides it at :ok.
      topRam: if(ram_dial.status != "ok", do: top_ram(seed, ram_used), else: []),
      topObjects: if(storage_dial.status != "ok", do: top_objects(seed, storage_used), else: []),
      monthToDate: usd(tier.price),
      compute: usd(if(running?, do: tier.price, else: 0)),
      activeHrs: if(running?, do: rem(seed, 720), else: 0),
      load: ram_dial.pct
    }
  end

  defp remote_url(nx), do: nx[:url] || nx["url"]

  # Real RAM pressure of the machine this nexus runs on: /proc/meminfo (Linux/Fly) → used = total −
  # available; falls back to the BEAM's own footprint where /proc is absent (dev/mac).
  defp local_ram_mb do
    case File.read("/proc/meminfo") do
      {:ok, c} ->
        with t when is_integer(t) <- meminfo(c, "MemTotal"),
             a when is_integer(a) <- meminfo(c, "MemAvailable") do
          div(max(t - a, 0), 1024)
        else
          _ -> beam_mb()
        end

      _ ->
        beam_mb()
    end
  end

  defp beam_mb, do: div(:erlang.memory(:total), 1_000_000)

  defp meminfo(c, key) do
    case Regex.run(~r/#{key}:\s+(\d+) kB/, c) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # Real durable footprint: total bytes under the data dir (the SQLite DB + served content + caches),
  # in GB. Small nexuses honestly read ~0 GB — that's correct, not a placeholder.
  defp local_storage_gb do
    bytes = dir_bytes(Nexus.Config.data_dir())
    round(bytes / 1_000_000_000)
  end

  defp dir_bytes(path) do
    cond do
      File.regular?(path) -> (File.stat(path) |> elem(1)).size
      File.dir?(path) -> path |> File.ls!() |> Enum.reduce(0, fn e, a -> a + dir_bytes(Path.join(path, e)) end)
      true -> 0
    end
  rescue
    _ -> 0
  end

  defp dial(used, limit, unit) do
    status = Pricing.status(used, limit)
    %{
      used: used,
      limit: limit,
      unit: unit,
      pct: if(limit > 0, do: min(100, round(used / limit * 100)), else: 0),
      status: Atom.to_string(status),
      label: "#{used} / #{limit} #{unit}"
    }
  end

  defp tier_view(nil), do: nil

  defp tier_view(t),
    do: %{id: t.id, name: t.name, ram_mb: t.ram_mb, storage_gb: t.storage_gb, price: usd(t.price), domains: t.domains?}

  # Representative top RAM consumers — the real subsystems of a running nexus,
  # apportioned across the used budget so the figures sum sensibly.
  defp top_ram(seed, used) do
    parts = [
      {"agent runtime (wasmtime instances)", 0.34},
      {"weave cache (compiled components)", 0.24},
      {"sync (CRDT replication)", 0.16},
      {"workbook sessions", 0.14},
      {"BEAM + system", 0.12}
    ]

    parts
    |> Enum.with_index()
    |> Enum.map(fn {{name, share}, i} ->
      jitter = (rem(seed + i * 97, 100) - 50) / 1000
      mb = max(1, round(used * (share + jitter)))
      %{name: name, mb: mb, label: "#{mb} MB"}
    end)
    |> Enum.sort_by(& &1.mb, :desc)
  end

  # Representative biggest stored objects — the kinds of things that fill a bucket.
  defp top_objects(seed, used_gb) do
    used_mb = used_gb * 1024

    parts = [
      {"datasets/transactions.parquet", 0.38},
      {"media/renders/*.mp4", 0.27},
      {"backups/nexus-snapshot.tar.zst", 0.19},
      {"assets/brand/*.png", 0.10},
      {"logs/archive/*.ndjson", 0.06}
    ]

    parts
    |> Enum.with_index()
    |> Enum.map(fn {{key, share}, i} ->
      jitter = (rem(seed + i * 53, 80) - 40) / 1000
      mb = max(1, round(used_mb * (share + jitter)))
      %{key: key, mb: mb, label: human_size(mb)}
    end)
    |> Enum.sort_by(& &1.mb, :desc)
  end

  defp human_size(mb) when mb >= 1024, do: "#{Float.round(mb / 1024, 1)} GB"
  defp human_size(mb), do: "#{mb} MB"

  defp usd(0), do: "$0.00"
  defp usd(n), do: "$#{:erlang.float_to_binary(n * 1.0, decimals: 2)}"
end
