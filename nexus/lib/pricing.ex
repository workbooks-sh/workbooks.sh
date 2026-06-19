defmodule Nexus.Pricing do
  @moduledoc """
  Tier ceilings for the one-nexus-per-org model — a generic **mechanism**, not a price list. A nexus
  auto-scales WITHIN its tier's RAM + storage ceiling; crossing it needs a scale-up (the next tier up,
  or — past the top tier — a new org). The only two dials are RAM and storage.

  THE LINE: the tier TABLE itself is **operator config**, read from `Nexus.Config.tiers/0` (a `.work`
  deploy declaration), never hardcoded here. The open-standard runtime ships a single neutral free
  tier; an operator (us included, via our DeployKit config) supplies their own tiers + prices. This
  module is only the logic over whatever table is configured — so the dashboard and platform API speak
  identical numbers, whatever those numbers are.

  Custom domains are a tier capability (`domains?`) — see `Nexus.ControlPlane.Domain`.
  """

  @doc "The configured tier table (operator config; one neutral free tier by default)."
  def tiers, do: Nexus.Config.tiers()

  @doc "The cheapest/default tier — the first in the configured order."
  def default_tier, do: List.first(tiers())

  @doc "The tier for a plan id, defaulting to the cheapest for unknown/nil ids."
  def tier(id), do: Enum.find(tiers(), &(&1.id == id)) || default_tier()

  @doc "The next tier up from a plan id, or nil at the ceiling (→ new org)."
  def next_tier(id) do
    ts = tiers()

    case Enum.find_index(ts, &(&1.id == id)) do
      nil -> Enum.at(ts, 1)
      idx -> Enum.at(ts, idx + 1)
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
