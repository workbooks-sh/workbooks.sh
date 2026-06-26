defmodule Nexus.Tiers do
  @moduledoc """
  **Seatless, committed-compute tiers** (wb-d8ac.11).

  The pricing story is radical — you pay for *compute*, not *seats* — but a variable bill scares a
  procurement officer. The answer is committed-compute tiers: a tier buys a committed compute
  allotment with a hard **cap** and **usage alerts**, so spend is bounded and predictable while
  staying seatless.

  THE LINE: this is a config-driven PRIMITIVE. The runtime parses neutral tier config and computes
  cap/alert state; it ships NO prices of its own. An operator supplies their own tiers via the
  `deploy tiers="…"` block (`Nexus.Config.tiers/0`); our actual prices live in OUR DeployKit config,
  never in `lib/`.

  Tier line format (`|`-separated, one tier per line, cheapest → biggest):

      id | Name | ram_mb storage_gb price_usd domains(yes|no) [compute_units]

  The optional 7th field, `compute_units`, is the committed-compute allotment (the cap). Omitted ⇒
  `nil` ⇒ uncapped (the neutral free tier). Everything here is pure over a string, so it's testable
  without booting a deploy.
  """

  @warn_pct 80

  @type tier :: %{
          id: String.t(),
          name: String.t(),
          ram_mb: integer,
          storage_gb: integer,
          price_usd: number,
          domains?: boolean,
          compute_units: integer | nil
        }

  @doc "All configured tiers (parsed from `Nexus.Config.tiers/0`); `[]` when unconfigured."
  @spec all() :: [tier]
  def all, do: parse(Nexus.Config.tiers())

  @doc "Parse a tiers config string into structured tiers. Blank/nil ⇒ `[]`. Malformed lines skipped."
  @spec parse(String.t() | nil) :: [tier]
  def parse(nil), do: []

  def parse(str) when is_binary(str) do
    str
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_line(line) do
    case line |> String.split("|") |> Enum.map(&String.trim/1) do
      [id, name, specs | _rest] ->
        # specs = "ram_mb storage_gb price_usd domains [compute_units]" — domains + compute optional.
        toks = String.split(specs, ~r/\s+/, trim: true)
        [ram, storage, price, domains, compute] = Enum.take(toks ++ [nil, nil, nil, nil, nil], 5)

        %{
          id: id,
          name: name,
          ram_mb: int(ram),
          storage_gb: int(storage),
          price_usd: num(price),
          domains?: domains in ["yes", "y", "true"],
          compute_units: int_or_nil(compute)
        }

      _ ->
        nil
    end
  end

  @doc "One tier by id, or `nil`."
  @spec tier(String.t()) :: tier | nil
  def tier(id), do: Enum.find(all(), &(&1.id == id))

  @doc """
  Usage status for a tier given `used` compute units: `%{used, cap, pct, state}` where `state` is
  `:ok` (< #{@warn_pct}%), `:warn` (≥ #{@warn_pct}%, < 100%), or `:over` (≥ 100%). An uncapped tier
  (`compute_units: nil`) is always `:ok` with `pct: 0` — the neutral free tier imposes no ceiling.
  """
  @spec usage_status(tier | nil, number) :: map
  def usage_status(nil, used), do: %{used: used, cap: nil, pct: 0, state: :ok}
  def usage_status(%{compute_units: nil}, used), do: %{used: used, cap: nil, pct: 0, state: :ok}

  def usage_status(%{compute_units: cap}, used) when is_number(used) and cap > 0 do
    pct = used / cap * 100
    state = cond do
      pct >= 100 -> :over
      pct >= @warn_pct -> :warn
      true -> :ok
    end

    %{used: used, cap: cap, pct: Float.round(pct, 1), state: state}
  end

  @doc "Should this usage raise an alert? (`:warn` or `:over`). The hook a notifier fires on."
  @spec alert?(tier | nil, number) :: boolean
  def alert?(tier, used), do: usage_status(tier, used).state in [:warn, :over]

  @doc "Is the cap exceeded? (a hard gate — refuse new committed work past the cap)."
  @spec over_cap?(tier | nil, number) :: boolean
  def over_cap?(tier, used), do: usage_status(tier, used).state == :over

  # ── parse helpers ────────────────────────────────────────────────────────────────────────────────
  defp int(v) when is_binary(v), do: v |> Integer.parse() |> case(do: ({n, _} -> n; :error -> 0))
  defp int(_), do: 0
  defp int_or_nil(v) when is_binary(v), do: v |> Integer.parse() |> case(do: ({n, _} -> n; :error -> nil))
  defp int_or_nil(_), do: nil
  defp num(v) when is_binary(v), do: v |> Float.parse() |> case(do: ({n, _} -> n; :error -> 0))
  defp num(_), do: 0
end
