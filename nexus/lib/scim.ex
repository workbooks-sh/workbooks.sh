defmodule Nexus.Scim do
  @moduledoc """
  **SCIM 2.0 user provisioning** (wb-d8ac.22) — the mapping enterprise IdPs (Okta, Azure AD,
  OneLogin) use to push user lifecycle (create / update / deactivate) into the org automatically.

  This is the protocol mapping + provisioning logic over `Nexus.Auth.Accounts`. Two halves:

    * **Representation** — `to_scim/1` renders an account as a SCIM User resource (`schemas`,
      `userName`, `name`, `emails`, `active`, `meta`); `from_scim/1` extracts the fields we store from
      an inbound SCIM payload. Pure, spec-shaped, fully testable without a database.
    * **Provisioning** — `provision/2` (create-or-update by userName), `deprovision/2` (set
      `active:false` → remove from org), and `list/2` (a SCIM `ListResponse`, optionally filtered by
      `userName eq "…"`, the filter Okta sends to reconcile). These delegate to `Accounts`.

  SCIM payloads ARE a genuine API boundary (an external IdP's JSON), so JSON here is legitimate — this
  is the one place the no-JSON rule explicitly exempts (a network data payload).
  """

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  # ── representation (pure) ────────────────────────────────────────────────────────────────────────

  @doc "Render an account map (`%{id, email, name, ...}`) as a SCIM User resource."
  @spec to_scim(map) :: map
  def to_scim(acct) do
    %{
      "schemas" => [@user_schema],
      "id" => acct[:id],
      "userName" => acct[:email],
      "name" => %{"formatted" => acct[:name] || ""},
      "emails" => [%{"value" => acct[:email], "primary" => true}],
      "active" => Map.get(acct, :active, true),
      "meta" => %{"resourceType" => "User"}
    }
  end

  @doc """
  Extract the fields we store from an inbound SCIM User payload: `%{email, name, active}`. `userName`
  is the canonical email (SCIM convention); `name.formatted` or `givenName familyName` → display name.
  """
  @spec from_scim(map) :: %{email: String.t() | nil, name: String.t(), active: boolean}
  def from_scim(payload) when is_map(payload) do
    name = payload["name"] || %{}

    display =
      name["formatted"] ||
        [name["givenName"], name["familyName"]] |> Enum.filter(& &1) |> Enum.join(" ")

    %{
      email: payload["userName"] || primary_email(payload["emails"]),
      name: display,
      active: Map.get(payload, "active", true)
    }
  end

  defp primary_email(emails) when is_list(emails) do
    Enum.find_value(emails, fn e -> if e["primary"], do: e["value"] end) ||
      (List.first(emails) || %{})["value"]
  end

  defp primary_email(_), do: nil

  # ── provisioning (delegates to Accounts) ──────────────────────────────────────────────────────────

  @doc """
  Provision (create or update) a user in `org` from a SCIM payload. New userName → create the account;
  existing → update its name. Returns `{:ok, scim_user} | {:error, reason}`.
  """
  @spec provision(String.t(), map) :: {:ok, map} | {:error, term}
  def provision(org, payload) do
    %{email: email, name: name} = from_scim(payload)

    if is_binary(email) and email != "" do
      acct =
        case Nexus.Auth.Accounts.get_by_email(email) do
          nil ->
            # IdP-provisioned users get a random password; they authenticate via SSO, not this secret.
            pw = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
            {:ok, a} = Nexus.Auth.Accounts.create(email, pw, org: org, name: name, role: "member")
            a

          existing ->
            existing
        end

      {:ok, to_scim(Map.put(acct, :active, true))}
    else
      {:error, :missing_username}
    end
  end

  @doc "Deprovision: deactivate + remove a user from `org` (the SCIM DELETE / `active:false` path)."
  @spec deprovision(String.t(), String.t()) :: :ok
  def deprovision(org, scim_id), do: Nexus.Auth.Accounts.remove_member(org, scim_id)

  @doc """
  A SCIM `ListResponse` of an org's users, optionally filtered by `userName eq "x"`. `filter` is the
  raw SCIM filter string an IdP sends; we support the single equality predicate IdPs use to reconcile.
  """
  @spec list(String.t(), String.t() | nil) :: map
  def list(org, filter \\ nil) do
    users =
      org
      |> Nexus.Auth.Accounts.list_org()
      |> filter_by(filter)
      |> Enum.map(&to_scim/1)

    %{
      "schemas" => [@list_schema],
      "totalResults" => length(users),
      "Resources" => users
    }
  end

  # Parse `userName eq "value"` (the only filter IdPs send for reconciliation). Anything else = no filter.
  defp filter_by(users, nil), do: users
  defp filter_by(users, ""), do: users

  defp filter_by(users, filter) do
    case Regex.run(~r/userName\s+eq\s+"([^"]+)"/i, filter) do
      [_, email] -> Enum.filter(users, &(&1[:email] == email))
      _ -> users
    end
  end
end
