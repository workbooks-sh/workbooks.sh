defmodule Nexus.Google do
  @moduledoc """
  Google Workspace **domain-wide delegation (DWD)** — the seam our agents use to operate a customer's
  whole Workspace domain: create users/mailboxes, manage aliases + `sendAs`, drive the Admin SDK, Gmail,
  Drive and Google Cloud. Unlike the 3-legged OAuth connector (which acts *as the one user who clicked
  Connect* and cannot touch domain-level resources), DWD acts as a **service account that impersonates
  any user in the domain** — the only model that can `users.insert` and `sendAs.create`.

  **One service account, many domains.** The SA lives in OUR GCP project (HOST secrets below). Each
  customer's super-admin authorizes the SA's numeric client id + scopes once in their Admin console
  (Security → API controls → Manage Domain-Wide Delegation). No per-user consent, no per-tenant SA key.
  The only per-tenant facts are the domain and which user to impersonate (`sub`) — those live on the
  integration connection record, not here.

  **Generic mechanism, no-op-safe.** With no SA configured (`configured?/0` false) every call returns
  `{:skip, reason}` — like `Nexus.GitHub`/`Nexus.JJ`, the feature is dark until secrets land. THE LINE:
  neutral Google plumbing any operator supplies their own SA for; our *policy* (which scopes, what the
  agent does) lives in the cloud product + `.work` config, not here.

  HOST secrets (via `Nexus.Secrets`, injected at deploy — never in source/`.work`):
    * `GOOGLE_SA_EMAIL`        — the service account address (`…@…iam.gserviceaccount.com`).
    * `GOOGLE_SA_PRIVATE_KEY`  — its private key (raw PEM, or base64-encoded PEM for single-line env).
    * `GOOGLE_SA_CLIENT_ID`    — the SA's numeric OAuth client id (what customer admins paste). Surfaced
      to the dashboard so the connect flow can show it; not used for signing.

  Token flow (RFC 7523 JWT-bearer): sign a short-lived RS256 assertion (iss = SA email, sub = the user
  to impersonate, scope = space-joined scopes, aud = token endpoint, ~1h exp) → POST it to Google's
  token endpoint → receive a bearer access token scoped to `scope`, acting as `sub`.

  `opts[:http]` injects a transport `(method, url, headers, body) -> {:ok,{status,body}} | {:error,_}`
  so tests exercise everything without a network; `opts[:email]`/`opts[:private_key]` override secrets.
  """
  require Logger

  @token_url "https://oauth2.googleapis.com/token"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @max_body_bytes 1024 * 1024

  @doc "Is the delegation service account configured (email + private key present)? Gates every call."
  def configured? do
    Nexus.Secrets.has?("GOOGLE_SA_EMAIL") and Nexus.Secrets.has?("GOOGLE_SA_PRIVATE_KEY")
  end

  @doc """
  The SA's numeric client id a customer admin pastes into their Admin console to authorize delegation.
  `nil` until configured — the dashboard shows it (plus the scope list) in the connect instructions.
  """
  def client_id, do: Nexus.Secrets.get("GOOGLE_SA_CLIENT_ID")

  @doc """
  Mint an impersonated access token. `sub` is the Workspace user to act as (a super-admin for Admin SDK
  calls, or the agent mailbox for Gmail calls); `scopes` is a list or space-joined string.

    `{:ok, %{access: token, expires_at: unix}} | {:skip, reason} | {:error, reason}`
  """
  def access_token(sub, scopes, opts \\ []) when is_binary(sub) do
    # signed_assertion/3 carries the configured-or-skip gate (it needs the same email + key), so we don't
    # re-check configured?/0 here — that also lets tests inject creds via opts without host secrets set.
    case signed_assertion(sub, scope_string(scopes), opts) do
      {:ok, jwt} -> exchange(jwt, opts)
      other -> other
    end
  end

  @doc """
  Sign the RS256 JWT-bearer assertion. Exposed (not just internal) so the token exchange can be tested
  independently. `{:ok, jwt} | {:skip, reason} | {:error, reason}`.
  """
  def signed_assertion(sub, scope, opts \\ []) do
    email = opts[:email] || Nexus.Secrets.get("GOOGLE_SA_EMAIL")
    pem = opts[:private_key] || private_key()

    with true <- is_binary(email) and is_binary(pem) || {:skip, "google service account not configured"} do
      now = System.os_time(:second)

      claims = %{
        "iss" => email,
        "sub" => sub,
        "scope" => scope_string(scope),
        "aud" => @token_url,
        "iat" => now - 30,
        "exp" => now + 3600
      }

      jwk = JOSE.JWK.from_pem(pem)
      {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
      {:ok, jwt}
    else
      {:skip, _} = skip -> skip
      _ -> {:error, :bad_sa_credentials}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── token exchange ───────────────────────────────────────────────────────────────────────────────
  defp exchange(jwt, opts) do
    form = URI.encode_query(%{"grant_type" => @jwt_bearer, "assertion" => jwt})
    headers = [{"accept", "application/json"}, {"content-type", "application/x-www-form-urlencoded"}]
    http = Keyword.get(opts, :http, &do_request/4)

    case http.(:post, @token_url, headers, form) do
      {:ok, {status, resp}} when status in 200..299 ->
        case Jason.decode(resp) do
          {:ok, %{"access_token" => access} = m} ->
            exp = m["expires_in"]
            {:ok, %{access: access, expires_at: if(is_integer(exp), do: System.os_time(:second) + exp, else: nil)}}

          _ ->
            {:error, :bad_token_response}
        end

      {:ok, {status, resp}} ->
        {:error, {:token_http, status, decode(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The SA private key, tolerant of injection style (raw multi-line PEM, or base64-encoded PEM for a
  # single-line env var — `base64 < sa-key.pem`). Mirrors Nexus.GitHub.private_key/0.
  defp private_key do
    case Nexus.Secrets.get("GOOGLE_SA_PRIVATE_KEY") do
      nil ->
        nil

      raw ->
        if String.contains?(raw, "BEGIN") do
          raw
        else
          case Base.decode64(String.trim(raw)) do
            {:ok, pem} -> pem
            :error -> raw
          end
        end
    end
  end

  defp scope_string(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  defp scope_string(scopes) when is_binary(scopes), do: scopes

  # TLS verified + SNI pinned to the fixed Google token host — the assertion can't be MITM-redirected.
  defp do_request(method, url, headers, body) do
    :inets.start()
    :ssl.start()
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    req = {to_charlist(url), hh, ~c"application/x-www-form-urlencoded", body}

    opts = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"oauth2.googleapis.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, cap(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

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
