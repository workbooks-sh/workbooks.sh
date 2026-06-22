defmodule Nexus.Google.Admin do
  @moduledoc """
  Google Workspace **provisioning** calls — the capability layer on top of `Nexus.Google`'s delegation
  tokens. These are the operations the agent actually performs on a connected domain:

    * `create_user/3`        — Admin SDK `users.insert`: a dedicated agent mailbox. **Consumes a paid
      Workspace seat** (billed to the customer) — prefer an alias where a separate login isn't needed.
    * `add_alias/4`          — Admin SDK `users.aliases.insert`: a free proxy address on an existing user.
    * `add_send_as/4`        — Gmail `settings.sendAs.create`: let a mailbox send as another address (free).
      DWD-only on Google's side, which is exactly the model we use.
    * `add_domain_alias/4`   — Admin SDK `domainAliases.insert`: a whole alternate domain (free).

  Each takes a delegation access token (mint it with `Nexus.Google.access_token/3`, impersonating a
  super-admin for Directory calls or the target mailbox for the Gmail call). Pure mechanism — no policy,
  no host secrets here. `opts[:http]` injects a transport for tests; `{:ok, body} | {:error, reason}`.
  """
  @directory "https://admin.googleapis.com/admin/directory/v1"
  @gmail "https://gmail.googleapis.com/gmail/v1"
  @max_body_bytes 1024 * 1024

  @doc "Create a Workspace user (a mailbox). NOTE: consumes a paid seat on the customer's account."
  def create_user(token, attrs, opts \\ []) when is_map(attrs) do
    body = %{
      "primaryEmail" => attrs[:primary_email] || attrs["primary_email"],
      "name" => %{
        "givenName" => attrs[:given_name] || attrs["given_name"] || "Agent",
        "familyName" => attrs[:family_name] || attrs["family_name"] || "Workbooks"
      },
      "password" => attrs[:password] || attrs["password"] || random_password(),
      "changePasswordAtNextLogin" => Map.get(attrs, :change_password, false)
    }

    request(:post, @directory <> "/users", token, body, opts)
  end

  @doc "Add a free alias (proxy address) to an existing user."
  def add_alias(token, user_key, alias_email, opts \\ []) do
    request(:post, @directory <> "/users/" <> enc(user_key) <> "/aliases", token, %{"alias" => alias_email}, opts)
  end

  @doc "Grant a mailbox the ability to send as another address (Gmail settings.sendAs)."
  def add_send_as(token, user_id, send_as_email, opts \\ []) do
    body = Map.merge(%{"sendAsEmail" => send_as_email}, opts[:send_as] || %{})
    request(:post, @gmail <> "/users/" <> enc(user_id) <> "/settings/sendAs", token, body, opts)
  end

  @doc "Register an alternate domain (domain alias) under the primary customer account."
  def add_domain_alias(token, customer, domain_alias, opts \\ []) do
    customer = customer || "my_customer"
    request(:post, @directory <> "/customer/" <> enc(customer) <> "/domainaliases", token, %{"domainAliasName" => domain_alias}, opts)
  end

  # ── authed JSON request ──────────────────────────────────────────────────────────────────────
  defp request(method, url, token, body, opts) do
    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> to_string(token)}
    ]

    http = Keyword.get(opts, :http, &do_request/4)

    case http.(method, url, headers, Jason.encode!(body)) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {:google_http, status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_request(method, url, headers, body) do
    :inets.start()
    :ssl.start()
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    host = URI.parse(url).host
    req = {to_charlist(url), hh, ~c"application/json", body}

    o = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, o, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, cap(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp enc(s), do: URI.encode(to_string(s), &URI.char_unreserved?/1)
  defp random_password, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp cap(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes, do: binary_part(bin, 0, @max_body_bytes)
  defp cap(bin), do: bin

  defp decode(""), do: %{}
  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      _ -> %{}
    end
  end

  defp decode(other), do: other
end
