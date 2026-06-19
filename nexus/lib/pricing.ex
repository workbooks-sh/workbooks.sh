defmodule Nexus.Pricing do
  @moduledoc """
  Tier ceilings for the one-nexus-per-org model. A nexus auto-scales WITHIN its
  tier's RAM + storage ceiling; crossing the ceiling needs a paid scale-up (the
  next tier up, or — past the top tier — a new org). The only two dials are RAM
  and storage: no seat billing, no per-request metering surfaced to the buyer.

  Custom domains are a paid-tier capability (Team and up) — see
  `Nexus.ControlPlane.Domain`. The tier table is the single source of truth both
  the dashboard and the platform API read, so "near capacity" / "scale up" speak
  identical numbers on both sides.
  """

  # ram_mb / storage_gb = the auto-scale ceiling; price = USD/mo; domains? gates
  # custom domains. Ordered cheapest → biggest; `next_tier` walks this order.
  @tiers [
    %{id: "starter", name: "Starter", ram_mb: 1_024, storage_gb: 10, price: 0, domains?: false},
    %{id: "team", name: "Team", ram_mb: 4_096, storage_gb: 100, price: 49, domains?: true},
    %{id: "scale", name: "Scale", ram_mb: 16_384, storage_gb: 1_000, price: 199, domains?: true}
  ]

  def tiers, do: @tiers

  @doc "The tier for a plan id, defaulting to the cheapest (starter) for unknown ids."
  def tier(id), do: Enum.find(@tiers, &(&1.id == id)) || List.first(@tiers)

  @doc "The next tier up from a plan id, or nil at the ceiling (→ new org)."
  def next_tier(id) do
    case Enum.find_index(@tiers, &(&1.id == id)) do
      nil -> Enum.at(@tiers, 1)
      idx -> Enum.at(@tiers, idx + 1)
    end
  end

  @doc "Whether a plan id may bind custom domains."
  def domains?(id), do: tier(id).domains?

  @doc "Capacity status for a `used`/`limit` reading: :ok | :near (≥80%) | :over (≥100%)."
  def status(used, limit) when is_number(used) and is_number(limit) and limit > 0 do
    cond do
      used / limit >= 1.0 -> :over
      used / limit >= 0.8 -> :near
      true -> :ok
    end
  end

  def status(_, _), do: :ok
end
