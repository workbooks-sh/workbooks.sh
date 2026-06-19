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
