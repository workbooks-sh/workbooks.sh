defmodule Nexus.Inference.Pricing do
  @moduledoc """
  Runtime model price registry — USD per **1M tokens**, `{input, output}`.

  The cloud layer's model-catalog fetch (which already pulls per-model input/output prices from the
  providers) calls `put_all/1`; the money boundary (`Nexus.Llm.complete` → `Nexus.Inference.Admission.cost/2`)
  reads `rate/1`. ONE price source, no duplicated or hardcoded prices — so EVERY paid call meters
  identically, including providers (Cloudflare Workers AI) that DON'T return a `cost` field in their
  response and must be priced from the token counts the response does carry.
  """
  @pt {__MODULE__, :rates}

  @doc """
  Register prices from a catalog: a list of maps with `:id` (or `"id"`) and `:price_in` / `:price_out`
  (USD per 1M tokens; either key form). Idempotent and cheap — only writes `persistent_term` when the
  resolved table actually changes, so per-call callers don't trigger a global GC pause every time.
  """
  @spec put_all([map]) :: :ok
  def put_all(models) when is_list(models) do
    incoming =
      for m <- models, id = m[:id] || m["id"], is_binary(id), reduce: %{} do
        acc ->
          pin = num(m[:price_in] || m["price_in"])
          pout = num(m[:price_out] || m["price_out"])
          if is_nil(pin) and is_nil(pout), do: acc, else: Map.put(acc, id, {pin, pout})
      end

    existing = :persistent_term.get(@pt, %{})
    merged = Map.merge(existing, incoming)
    if merged != existing, do: :persistent_term.put(@pt, merged)
    :ok
  end

  def put_all(_), do: :ok

  @doc """
  Blended USD/1M-token rate (the mean of input + output) for a model id, matching either gateway id form
  (`workers-ai/@cf/…` or the bare `@cf/…`). `nil` when the model isn't in the registry yet.
  """
  @spec rate(String.t() | nil) :: float | nil
  def rate(model) when is_binary(model) do
    rates = :persistent_term.get(@pt, %{})

    case rates[model] || rates[alias_form(model)] do
      {pin, pout} -> ((pin || pout || 0.0) + (pout || pin || 0.0)) / 2
      _ -> nil
    end
  end

  def rate(_), do: nil

  # CF models route under both `workers-ai/@cf/…` (gateway compat) and the bare `@cf/…`; match either.
  defp alias_form("workers-ai/" <> rest), do: rest
  defp alias_form(m), do: "workers-ai/" <> m

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: nil
end
