defmodule Nexus.Auth.Provider do
  @moduledoc """
  OAuth2 / OIDC login flows — the provider half of the native auth feature (RFC
  nexus/AUTH-ROUTING-RFC.md, epic wb-0uil). The nexus serves `/auth/:provider/login` (this module's
  `login/2`, here) and `/auth/:provider/callback` (the callback slice, wb-ahr6).

  THE LINE: the standard ships **no provider**. A deployer declares providers as config —
  `auth-provider-<name>-authorize-url`, `-token-url`, `-jwks-url`, `-client-id`, `-redirect-uri`,
  `-scope`, `-issuer`, `-tenant-claim` (Nexus.Config) — and the client secret in `Nexus.Secrets`
  (`<NAME>_CLIENT_SECRET`). WorkOS is just one such configured provider; nothing is baked in.

  ## Login (this slice): redirect + CSRF state

  `login/2` mints a random `state` + `nonce`, stores them in a **short-lived, signed, httpOnly**
  cookie (the CSRF anchor — the callback must echo the matching `state`), and 302-redirects to the
  provider's authorize endpoint. The authorize URL MUST be https (a cleartext authorize/token/jwks URL
  is a trivial MITM). `verify_state/1` (used by the callback) re-opens the signed cookie.
  """
  import Plug.Conn

  @state_cookie "wb_oauth_state"
  @salt "wb_oauth_state_v1"
  @state_ttl 600
  @default_scope "openid email profile"

  @doc "Begin login for `provider`: set the signed state cookie + 302 to the authorize endpoint."
  def login(conn, provider, opts \\ []) do
    cfg = Nexus.Config.provider(provider)
    authorize = cfg["authorize-url"]

    cond do
      not is_binary(authorize) or authorize == "" -> send_resp(conn, 404, "unknown auth provider")
      not https?(authorize) -> send_resp(conn, 500, "provider authorize-url must be https")
      true -> redirect(conn, provider, cfg, opts)
    end
  end

  defp redirect(conn, provider, cfg, opts) do
    state = nonce()
    nonce = nonce()
    signed = Plug.Crypto.sign(key(), @salt, %{s: state, n: nonce, p: to_string(provider)})

    conn
    |> put_resp_cookie(@state_cookie, signed,
      http_only: true,
      same_site: "Lax",
      secure: secure?(conn),
      max_age: @state_ttl,
      path: "/"
    )
    |> put_resp_header("location", authorize_url(cfg, state, nonce, opts))
    |> send_resp(302, "")
  end

  @doc "Build the provider's authorize URL with the OAuth2/OIDC params."
  def authorize_url(cfg, state, nonce, opts \\ []) do
    base = cfg["authorize-url"]

    q =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => cfg["client-id"] || "",
        "redirect_uri" => cfg["redirect-uri"] || opts[:redirect_uri] || "",
        "scope" => cfg["scope"] || @default_scope,
        "state" => state,
        "nonce" => nonce
      })

    base <> if(String.contains?(base, "?"), do: "&", else: "?") <> q
  end

  @doc """
  Read + verify the signed state cookie (used by the callback). Returns `{:ok, %{s, n, p}}` (the state,
  nonce, provider) or `:error` (absent / tampered / expired). The callback compares `s` to the
  returned `state` query param (CSRF) and `n` to the id_token's `nonce` (replay).
  """
  def verify_state(conn) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.cookies[@state_cookie],
         {:ok, %{s: _, n: _, p: _} = data} <- Plug.Crypto.verify(key(), @salt, token, max_age: @state_ttl) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  @doc "Clear the state cookie (after a callback, success or fail)."
  def clear_state(conn), do: delete_resp_cookie(conn, @state_cookie, path: "/")

  @doc false
  def state_cookie, do: @state_cookie

  @doc """
  Complete a login. Verifies CSRF `state`, exchanges the `code` for tokens (server-to-server,
  client_secret from `Nexus.Secrets`, TLS-verified), verifies the `id_token` (vetted `Nexus.Auth.Jwt`,
  provider jwks/issuer), checks the `nonce` (replay), maps claims → identity, issues a session cookie,
  and 302s to the post-login path. Any failure → 401 with the state cookie cleared. Opts `:exchange` /
  `:verify_id` are DI seams for tests.
  """
  def callback(conn, provider, opts \\ []) do
    cfg = Nexus.Config.provider(provider)
    exchange = opts[:exchange] || (&exchange_code/3)
    verify_id = opts[:verify_id] || (&verify_id_token/3)
    conn = fetch_query_params(conn)
    p = conn.query_params

    with {:ok, %{s: want_state, n: nonce}} <- verify_state(conn),
         code when is_binary(code) and code != "" <- p["code"],
         state when is_binary(state) <- p["state"],
         true <- Plug.Crypto.secure_compare(state, want_state),
         {:ok, tokens} <- exchange.(provider, cfg, code),
         id_token when is_binary(id_token) <- tokens["id_token"],
         {:ok, claims} <- verify_id.(id_token, cfg, nonce),
         %{tenant: t} = identity when is_binary(t) and t != "" <- map_claims(claims, cfg) do
      conn
      |> clear_state()
      |> Nexus.Auth.Session.issue(identity)
      |> put_resp_header("location", cfg["post-login"] || "/")
      |> send_resp(302, "")
    else
      _ -> conn |> clear_state() |> send_resp(401, "authentication failed")
    end
  end

  # Server-to-server code→token exchange. TLS-VERIFIED (it carries the client secret); token-url MUST
  # be https. Returns the decoded token response map or `{:error, _}`.
  defp exchange_code(provider, cfg, code) do
    url = cfg["token-url"]

    if https?(url) do
      form =
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => cfg["redirect-uri"] || "",
          "client_id" => cfg["client-id"] || "",
          "client_secret" => Nexus.Secrets.get(secret_name(provider)) || ""
        })

      post_form(url, form)
    else
      {:error, :insecure_token_url}
    end
  end

  defp post_form(url, form) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    req = {String.to_charlist(url), [{~c"accept", ~c"application/json"}], ~c"application/x-www-form-urlencoded", String.to_charlist(form)}
    http_opts = [ssl: ssl_opts, timeout: 15_000, connect_timeout: 15_000]

    case :httpc.request(:post, req, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _h, body}} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> {:ok, m}
          _ -> {:error, :bad_token_response}
        end

      _ ->
        {:error, :token_exchange_failed}
    end
  end

  defp secret_name(provider), do: String.upcase(to_string(provider)) <> "_CLIENT_SECRET"

  # Verify the id_token against the PROVIDER's jwks/issuer (not the global adapter), then the nonce.
  defp verify_id_token(id_token, cfg, nonce) do
    overrides = [jwks_url: cfg["jwks-url"], issuer: cfg["issuer"], secret: cfg["hs256-secret"]]

    with {:ok, claims} <- Nexus.Auth.Jwt.verify(id_token, overrides),
         true <- nonce_ok?(claims, nonce) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  # OIDC: we always send a nonce, so the id_token MUST echo it. Absent/mismatched ⇒ fail-closed.
  defp nonce_ok?(%{"nonce" => n}, nonce) when is_binary(n), do: Plug.Crypto.secure_compare(n, nonce)
  defp nonce_ok?(_, _), do: false

  defp map_claims(claims, cfg) do
    %{
      tenant: to_string(claims[cfg["tenant-claim"] || "sub"] || ""),
      user: claims[cfg["user-claim"] || "sub"],
      roles: as_list(claims[cfg["roles-claim"] || "roles"]),
      scopes: as_list(claims[cfg["scopes-claim"] || "scope"])
    }
  end

  defp as_list(l) when is_list(l), do: Enum.map(l, &to_string/1)
  defp as_list(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp as_list(_), do: []

  # ── internals ──
  defp https?(url), do: is_binary(url) and String.starts_with?(url, "https://")
  defp nonce, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  defp secure?(conn), do: Nexus.Config.session_secure?() or conn.scheme == :https

  # Same key resolution as Nexus.Auth.Session: deploy secret, or a per-boot random key in dev.
  defp key do
    case Nexus.Secrets.get("WB_SESSION_SECRET") do
      v when is_binary(v) and byte_size(v) >= 16 -> v
      _ -> dev_key()
    end
  end

  defp dev_key do
    case :persistent_term.get({__MODULE__, :dev_key}, nil) do
      nil ->
        k = Base.url_encode64(:crypto.strong_rand_bytes(32))
        :persistent_term.put({__MODULE__, :dev_key}, k)
        k

      k ->
        k
    end
  end
end
