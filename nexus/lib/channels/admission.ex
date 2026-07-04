defmodule Nexus.Channels.Admission do
  @moduledoc """
  The money-boundary gate for external communication channels (SMS/voice — the phone channel that
  lets a paying tenant text/call their autopoet, epic wb-h0pey). Every paid outbound send and every
  metered inbound-triggered reply passes `admit/3` BEFORE the Telnyx call leaves the box, and reports
  its spend through `charge/2` after — the exact `Nexus.Inference.Admission` pattern at a different
  provider boundary.

  **Why it lives in core, not the cloud layer.** The enforcement point is the channel-send boundary
  (`Nexus.Telnyx` callsites): any entry path — webhook reply, agent-initiated send, scheduled
  notification — has to cross it to spend money.

  **Why it stays neutral (the line).** No billing opinion here. A generic policy enforcer driven by
  DATA the cloud control plane writes into `Nexus.ControlPlane` under `(tenant, :channels, "config")`:

      %{
        enforce:     true,           # master switch — absent/false ⇒ admit everything
        balance:     12.50,          # remaining channel credit (USD); <= 0 ⇒ :insufficient_credit
        spent_mtd:   3.20,           # spend this calendar month (USD)
        monthly_cap: 25.0,           # optional ceiling; spent_mtd >= cap ⇒ :monthly_cap_exceeded
        caps:        %{sms: true, voice: false},  # per-modality switches (the kill switch); absent ⇒ on
        rates:       %{sms: 0.01, voice: 0.10}    # USD per unit (SMS segment / voice minute) — cloud's fee schedule
      }

  The cloud layer owns the opinion (which plan gets the channel, the fee schedule, top-ups); core
  owns only the enforcement. A tenant runtime with no such record — or a single-tenant/dev box with
  `tenant == nil` — is trusted and admitted, so the open-standard runtime is unaffected.
  """

  @kind :channels
  @id "config"

  @type modality :: :sms | :voice
  @type reason :: :insufficient_credit | :capability_disabled | :monthly_cap_exceeded

  @doc """
  Decide whether a channel `modality` (`:sms` | `:voice`) may be used for `tenant`. Returns `:ok`
  or `{:error, reason}`. Trusted/unconfigured callers always get `:ok`.
  """
  @spec admit(binary | nil, modality, keyword) :: :ok | {:error, reason}
  def admit(tenant, modality, opts \\ [])

  def admit(tenant, _modality, _opts) when not is_binary(tenant), do: :ok

  def admit(tenant, modality, _opts) do
    cfg = config(tenant)

    if Map.get(cfg, :enforce) == true do
      cond do
        not capability_on?(cfg, modality) -> {:error, :capability_disabled}
        balance(cfg) <= 0.0 -> {:error, :insufficient_credit}
        over_monthly_cap?(cfg) -> {:error, :monthly_cap_exceeded}
        true -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Record `amount` USD of channel spend against `tenant`: subtract from `balance`, add to
  `spent_mtd`. Best-effort; no-op for trusted callers or when enforcement is off. Never raises —
  metering must never break a send.
  """
  @spec charge(binary | nil, number) :: :ok
  def charge(tenant, amount) when is_binary(tenant) and is_number(amount) and amount > 0 do
    cfg = config(tenant)

    if Map.get(cfg, :enforce) == true do
      upd = %{
        balance: Float.round(balance(cfg) - amount, 6),
        spent_mtd: Float.round(spent(cfg) + amount, 6)
      }

      _ = Nexus.ControlPlane.update(tenant, @kind, @id, upd)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def charge(_tenant, _amount), do: :ok

  @doc """
  USD cost of `units` of a modality (SMS segments / voice minutes) under the tenant's fee schedule.
  An absent rate prices to 0.0 — an unpriced channel meters nothing, it does not block (blocking is
  `admit/3`'s job). The ONE place channel spend is derived, so every send meters identically.
  """
  @spec cost(binary | nil, modality, number) :: float
  def cost(tenant, modality, units) when is_number(units) and units > 0 do
    Float.round(units * rate(config(tenant), modality), 6)
  end

  def cost(_tenant, _modality, _units), do: 0.0

  @doc """
  The number of SMS segments `text` occupies on the wire — the billing unit for `:sms`. GSM-7
  messages split at 160 chars (153 per part when multipart); anything needing UCS-2 (emoji, most
  non-Latin scripts) splits at 70/67. Approximation errs on the carrier-accurate side for billing.
  """
  @spec sms_segments(binary) :: pos_integer
  def sms_segments(text) when is_binary(text) do
    len = String.length(text)

    {single, multi} = if gsm7?(text), do: {160, 153}, else: {70, 67}

    cond do
      len == 0 -> 1
      len <= single -> 1
      true -> div(len + multi - 1, multi)
    end
  end

  # The GSM 03.38 basic charset + extension, approximated: ASCII printable + the common GSM extras.
  # Any char outside forces UCS-2 encoding for the whole message (per the SMS spec).
  defp gsm7?(text) do
    String.to_charlist(text)
    |> Enum.all?(fn c ->
      (c >= 0x20 and c <= 0x7E) or c in [?\n, ?\r, 0xA3, 0xA5, 0xE9, 0xE8, 0xFC, 0xF6, 0xE4, 0xC4, 0xD6, 0xDC, 0xDF, 0xE0]
    end)
  end

  @doc """
  Human-facing classification of a block reason. `:credit` reasons mean the team is out of money
  (admin can top up); `:policy` reasons are a configuration choice (plan gate / kill switch).
  """
  @spec kind(reason) :: :credit | :policy
  def kind(:insufficient_credit), do: :credit
  def kind(:monthly_cap_exceeded), do: :credit
  def kind(_), do: :policy

  # ── policy reads ────────────────────────────────────────────────────────────────

  defp config(tenant) when is_binary(tenant) do
    case Nexus.ControlPlane.get(tenant, @kind, @id) do
      {:ok, c} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp config(_), do: %{}

  defp balance(cfg), do: num(Map.get(cfg, :balance))
  defp spent(cfg), do: num(Map.get(cfg, :spent_mtd))

  defp rate(cfg, modality) do
    case Map.get(cfg, :rates) do
      rates when is_map(rates) -> num(Map.get(rates, modality, Map.get(rates, to_string(modality))))
      _ -> 0.0
    end
  end

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0

  # caps is the per-modality kill switch; an absent map or absent key means the modality is enabled.
  defp capability_on?(cfg, modality) do
    case Map.get(cfg, :caps) do
      caps when is_map(caps) -> Map.get(caps, modality, Map.get(caps, to_string(modality), true)) != false
      _ -> true
    end
  end

  defp over_monthly_cap?(cfg) do
    case Map.get(cfg, :monthly_cap) do
      cap when is_number(cap) and cap > 0 -> spent(cfg) >= cap
      _ -> false
    end
  end
end
