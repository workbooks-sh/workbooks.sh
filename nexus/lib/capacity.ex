defmodule Nexus.Capacity do
  @moduledoc """
  Capacity feedback for a nexus — RAM + storage used against the tier ceiling,
  and, when the dial runs hot, WHAT to shed: the top RAM consumers and the
  biggest stored objects. The nexus auto-scales within its ceiling; this is the
  signal the dashboard turns into "near capacity → scale up to continue".

  This is the SHOWCASE backend: the per-nexus reading is derived deterministically
  from the nexus id + run state (the control plane can't yet pull live tenant-VM
  metrics — that Fly-grounded backend layers onto this same shape next). Numbers
  are stable per nexus, so the dashboard never flickers, and the math (used vs the
  `Nexus.Pricing` ceiling, the near/over thresholds) is the real production logic.
  """
  import Bitwise
  alias Nexus.Pricing

  @doc "The full usage + capacity report for an org's (single) nexus."
  def report(nil) do
    tier = Pricing.tier("starter")
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

  def report(nx) do
    tier = Pricing.tier(nx[:plan] || "starter")
    running? = nx[:state] == "running"
    seed = :erlang.phash2(nx[:id] || "nx")

    ram_used = if running?, do: scaled(seed, tier.ram_mb, 0.55, 0.97), else: 0
    storage_used = scaled(seed >>> 3, tier.storage_gb, 0.30, 0.95)

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

  # A used reading in [lo, hi] of the ceiling, deterministic in the seed.
  defp scaled(seed, ceiling, lo, hi) do
    frac = lo + rem(seed, 1000) / 1000 * (hi - lo)
    round(ceiling * frac)
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
