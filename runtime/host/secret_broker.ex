defmodule Workbooks.SecretBroker do
  @moduledoc """
  wb-broker SECRETS (host holds creds) — the host holds named secrets per tenant; a guest can USE a secret
  (HMAC-sign data with it) but can NEVER read its value. The privileged thing the host does is hold the key
  and apply it; the guest only ever sees the SIGNATURE, never the secret. This is how a sandboxed guest
  authenticates a webhook / API request / JWT without ever possessing the credential.

  Security:
    * NO READ — there is deliberately no function that returns a secret's value. The only guest-reachable op
      is `sign/3`. Secrets live in this Agent's private state, never crossing the membrane.
    * TENANT ISOLATION — secrets are scoped per tenant; a tenant can only sign with its own secrets.
    * REVOCATION — a revoked tenant cannot sign.
  """
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Host-side: register a secret for a tenant (from config/env). Never exposed to the guest."
  def register(tenant, name, value)
      when is_binary(tenant) and is_binary(name) and is_binary(value) do
    Agent.update(agent(), fn state ->
      Map.update(state, tenant, %{name => value}, &Map.put(&1, name, value))
    end)
  end

  @doc """
  Guest-reachable: HMAC-SHA256 `data` with the tenant's named secret. Returns `{:ok, signature_bytes}` —
  the guest gets the SIGNATURE, never the key. `{:error, :unknown_secret | :revoked}` otherwise.
  """
  def sign(tenant, name, data)
      when is_binary(tenant) and is_binary(name) and is_binary(data) do
    if Workbooks.Revocation.revoked?(tenant) do
      {:error, :revoked}
    else
      Agent.get(agent(), fn state ->
        case state[tenant][name] do
          nil -> {:error, :unknown_secret}
          secret -> {:ok, :crypto.mac(:hmac, :sha256, secret, data)}
        end
      end)
    end
  end

  defp agent do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        __MODULE__

      pid ->
        pid
    end
  end
end
