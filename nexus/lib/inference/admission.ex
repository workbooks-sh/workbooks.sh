defmodule Nexus.Inference.Admission do
  @moduledoc """
  The money-boundary gate for inference. Every paid call to a provider — a text completion
  (`Nexus.Llm.complete`) or an asset generation (`Nexus.Generator.run`) — passes through
  `admit/3` BEFORE the request leaves the box, and reports its spend through `charge/2` after.

  **Why it lives in core, not the cloud layer.** Enforcing the gate at the provider boundary is the
  only place it cannot be subverted: a different entry path (SSE run, blocking run, a generator
  command inside an agent loop, a direct API caller) still has to cross `Llm.complete`/`Generator.run`
  to spend money, so it still has to pass `admit/3`. If the gate lived in one of the request handlers,
  another handler could bypass it.

  **Why it stays neutral (the line).** This module bakes in NO billing opinion. It is a generic
  policy *enforcer* driven entirely by DATA the cloud control plane writes into `Nexus.ControlPlane`
  under `(tenant, :inference, "config")`:

      %{
        enforce:      true,          # master switch — absent/false ⇒ admit everything
        balance:      12.50,         # remaining credit (USD); <= 0 ⇒ :insufficient_credit
        spent_mtd:    3.20,          # spend this calendar month (USD)
        monthly_cap:  100.0,         # optional ceiling; spent_mtd >= cap ⇒ :monthly_cap_exceeded
        allow_ids:    ["anthropic/claude-opus-4.8", ...],  # the resolved model allow-list; absent ⇒ all
        caps:         %{image: true, video: false, audio: true}  # per-modality switches; absent ⇒ on
      }

  The cloud layer owns the *opinion* (what a "frontier" group is, the fee schedule, how `allow_ids`
  is computed from an admin's group rules); core owns only the *enforcement* of whatever data is
  present. A tenant runtime with no such record — or a single-tenant/dev box with `tenant == nil` —
  is trusted and admitted, so the open-standard runtime is unaffected.
  """

  @kind :inference
  @id "config"

  @type reason ::
          :insufficient_credit
          | :model_not_allowed
          | :capability_disabled
          | :monthly_cap_exceeded

  @doc """
  Decide whether a `model` (and, for generators, a non-text `:modality`) may run for `tenant`.
  Returns `:ok` or `{:error, reason}`. Trusted/unconfigured callers always get `:ok`.
  """
  @spec admit(binary | nil, binary | nil, keyword) :: :ok | {:error, reason}
  def admit(tenant, model, opts \\ [])

  def admit(tenant, _model, _opts) when not is_binary(tenant), do: :ok

  def admit(tenant, model, opts) do
    cfg = config(tenant)

    if Map.get(cfg, :enforce) == true do
      modality = opts[:modality] || :text

      cond do
        not capability_on?(cfg, modality) -> {:error, :capability_disabled}
        not model_allowed?(cfg, model) -> {:error, :model_not_allowed}
        balance(cfg) <= 0.0 -> {:error, :insufficient_credit}
        over_monthly_cap?(cfg) -> {:error, :monthly_cap_exceeded}
        true -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Record `amount` USD of spend against `tenant`: subtract from `balance`, add to `spent_mtd`.
  Best-effort and idempotent-safe to call once per completed paid call. No-op for trusted callers
  or when enforcement is off (nothing to debit). Never raises — metering must never break a run.
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
  USD cost of a completed call from the provider-reported `usage`. Prefers the real `cost` field
  (OpenRouter with `usage.include`); else estimates from total tokens × `rate` (USD per 1M tokens) when
  a rate is supplied; else 0.0 (never guess high). This is the ONE place spend is derived from a turn, so
  every paid call meters identically.
  """
  @spec cost(map, number) :: float
  def cost(usage, rate \\ 0.0)

  def cost(usage, rate) when is_map(usage) do
    cond do
      is_number(usage["cost"]) -> usage["cost"] / 1
      is_number(usage[:cost]) -> usage[:cost] / 1
      is_number(rate) and rate > 0 ->
        toks = cost_num(usage["total_tokens"]) || (cost_num(usage["prompt_tokens"]) || 0) + (cost_num(usage["completion_tokens"]) || 0)
        Float.round(toks / 1_000_000 * rate, 6)

      true ->
        0.0
    end
  end

  def cost(_, _), do: 0.0

  defp cost_num(n) when is_number(n), do: n
  defp cost_num(_), do: nil

  @doc """
  Human-facing classification of a block reason, for the client modal. `:credit` reasons mean the
  team is out of money (admin can top up); `:policy` reasons are an admin configuration choice.
  """
  @spec kind(reason) :: :credit | :policy
  def kind(:insufficient_credit), do: :credit
  def kind(:monthly_cap_exceeded), do: :credit
  def kind(_), do: :policy

  # ── policy reads ────────────────────────────────────────────────────────────────────────────────

  defp config(tenant) do
    case Nexus.ControlPlane.get(tenant, @kind, @id) do
      {:ok, c} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp balance(cfg), do: num(Map.get(cfg, :balance))
  defp spent(cfg), do: num(Map.get(cfg, :spent_mtd))

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0

  # An absent allow-list means "no restriction" (every catalog model is fine). A present list gates.
  defp model_allowed?(cfg, model) do
    case Map.get(cfg, :allow_ids) do
      ids when is_list(ids) and ids != [] -> to_string(model) in ids
      _ -> true
    end
  end

  # caps is a per-modality switch map; an absent map or absent key means the modality is enabled.
  # Text is never gated by a capability toggle (it is the base inference primitive).
  defp capability_on?(_cfg, :text), do: true

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
