defmodule Nexus.Auth.Sso do
  @moduledoc """
  **Enterprise SSO enforcement** (wb-d8ac.21).

  The OIDC/OAuth2 login *mechanism* already exists (`Nexus.Auth.Provider` — config-driven authorize +
  callback, CSRF-anchored; WorkOS/Okta/Azure AD all speak OIDC). What enterprise buyers additionally
  require is **org-level enforcement**: claim an email domain for the org, route those users through a
  specific identity provider, and (optionally) forbid password login so every employee MUST come
  through SSO. This module is that policy layer, on the org-isolated control-plane store (kind `:sso`).

  THE LINE: still no IdP baked in — an org points its domain at one of its own configured providers.
  """
  alias Nexus.ControlPlane, as: CP

  @doc """
  Claim `domain` for `org`, routing its users through `provider`. `required: true` forbids non-SSO
  (password) login for that domain. Returns `{:ok, record}`.
  """
  @spec configure(String.t(), String.t(), String.t(), keyword) :: {:ok, map}
  def configure(org, domain, provider, opts \\ []) when is_binary(domain) and is_binary(provider) do
    out =
      CP.put(org, :sso, normalize(domain), %{
        domain: normalize(domain),
        provider: provider,
        required: Keyword.get(opts, :required, false),
        created_at: System.os_time(:millisecond)
      })

    index(org, domain)
    out
  end

  @doc "The SSO record for an email's domain (searched across orgs by domain), or `nil`."
  @spec for_email(String.t()) :: map | nil
  def for_email(email) when is_binary(email) do
    case domain_of(email) do
      nil -> nil
      domain -> find_domain(domain)
    end
  end

  @doc "Must this email log in via SSO (no password)? True iff its domain is claimed AND required."
  @spec required?(String.t()) :: boolean
  def required?(email) do
    case for_email(email) do
      %{required: true} -> true
      _ -> false
    end
  end

  @doc "Which provider an email should be routed to, or `nil` if its domain isn't claimed."
  @spec provider_for(String.t()) :: String.t() | nil
  def provider_for(email) do
    case for_email(email), do: (%{provider: p} -> p; _ -> nil)
  end

  @doc "Remove a domain claim."
  def remove(org, domain), do: CP.delete(org, :sso, normalize(domain))

  # A domain claim is org-scoped in storage but resolved globally by domain (an email arrives before we
  # know its org). We scan known orgs' :sso records; the domain key is unique across orgs by contract.
  defp find_domain(domain) do
    # CP has no cross-org scan; the resolver keeps a domain→org index alongside the org record.
    # NB: CP.put stamps the record's :org to the PUT org (here the index org), so the real target org
    # is stored under :target_org.
    case CP.get(index_org(), :sso_index, domain) do
      {:ok, %{target_org: org}} ->
        case CP.get(org, :sso, domain), do: ({:ok, rec} -> rec; _ -> nil)

      _ ->
        nil
    end
  end

  # Maintain a global domain→org index so for_email/1 can resolve without an org in hand.
  @doc false
  def index(org, domain) do
    CP.put(index_org(), :sso_index, normalize(domain), %{domain: normalize(domain), target_org: org})
  end

  defp index_org, do: "__sso_index__"
  defp normalize(d), do: d |> String.trim() |> String.downcase()
  defp domain_of(email), do: case(String.split(email, "@"), do: ([_u, d] -> normalize(d); _ -> nil))
end
