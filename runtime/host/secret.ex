defmodule Workbooks.Secret do
  @moduledoc """
  Secrets-by-reference (L2, docs/SECRETS.org). A Workbook references a secret by
  *name*; the host resolves the *value* only inside a host-side operation and
  never returns it to the guest. This module is the resolver + the injection
  primitive `net-fetch` (and any egress Dock import) uses.

  The guarantee is structural: there is `get/1` (host-only) and `present?/1`
  (the only secret-shaped thing a guest may observe — existence, never content),
  but deliberately *no* Dock import that returns a value. `inject/1` substitutes
  `{{secret:NAME}}` placeholders host-side, just before egress; the resolved
  bytes are never written into guest linear memory.

  One behaviour, many impls, chosen per deploy cell (same shape as the storage
  `Backend`): `Secret.Env` for local/dev; 1Password/AWS/Vault/Varlock for prod.
  """

  @callback get(name :: String.t()) :: {:ok, String.t()} | :error
  @callback present?(name :: String.t()) :: boolean()

  @placeholder ~r/\{\{secret:([A-Za-z0-9_]+)\}\}/

  @doc "The deploy-cell secret backend; default Secret.Env."
  def backend, do: Application.get_env(:workbooks, :secret_backend, Workbooks.Secret.Env)

  @doc "Host-only: resolve a secret value. Never expose the result to a guest."
  def get(name), do: backend().get(name)

  @doc "Existence check — the only secret-shaped value a guest may read."
  def present?(name), do: backend().present?(name)

  @doc """
  Substitute `{{secret:NAME}}` placeholders with resolved values, host-side. An
  unresolved name is left *literal* (a visible failure — the downstream call
  fails auth) rather than blanked, so a missing secret never silently succeeds.
  """
  def inject(template) when is_binary(template) do
    Regex.replace(@placeholder, template, fn whole, name ->
      case get(name) do
        {:ok, value} -> value
        :error -> whole
      end
    end)
  end
end
