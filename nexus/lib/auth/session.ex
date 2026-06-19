defmodule Nexus.Auth.Session do
  @moduledoc """
  Signed, httpOnly cookie sessions — the BetterAuth half of the native auth feature (RFC
  nexus/AUTH-ROUTING-RFC.md, epic wb-0uil). A login flow calls `issue/3` to set a tamper-proof
  session cookie carrying the identity; every later request verifies it with `verify/1`. The
  `Nexus.Auth.Cookie` adapter wires `verify/1` into the request pipeline.

  ## Security

    * **Signed, not encrypted** — `Plug.Crypto.sign/verify` (HMAC) over the identity claims, so a
      client cannot forge or tamper; claims are NOT secret (no passwords/keys ever go in a session).
    * **Key from `Nexus.Secrets`** (`WB_SESSION_SECRET`) — never hardcoded, never in source. With no
      secret set (local dev) a **per-boot random** key is used: sessions work but don't survive a
      restart and can't be forged. Production MUST set the secret (shared across instances).
    * Cookie is **httpOnly** (no JS access → XSS can't steal it), **SameSite=Lax** (blocks the common
      cross-site CSRF vector on top-level POSTs), **Secure** by default (`session_secure?` — https
      only; an http dev nexus opts out via config), short-lived (`session_max_age`, default 24h) with
      a baked `iat`/`max_age` so an expired cookie is rejected.
    * **Sliding rotation** — `verify/1` reports `{:ok, identity, :renew}` past the halfway mark so the
      caller can re-`issue/3`, extending an active session without an unbounded lifetime.
  """
  @salt "wb_session_v1"

  @doc "Set the session cookie on `conn` for `identity`. Opts: `:max_age` (seconds)."
  def issue(conn, identity, opts \\ []) do
    max_age = opts[:max_age] || Nexus.Config.session_max_age()

    claims =
      identity
      |> Map.take([:tenant, :user, :roles, :scopes])
      |> Map.put(:iat, now())

    token = Plug.Crypto.sign(secret(), @salt, claims)

    Plug.Conn.put_resp_cookie(conn, cookie(), token,
      http_only: true,
      same_site: "Lax",
      secure: secure?(conn),
      max_age: max_age,
      path: "/"
    )
  end

  @doc """
  Verify the request's session cookie. Returns `{:ok, identity}`, `{:ok, identity, :renew}` (valid but
  past half-life — re-issue to slide), or `:error` (absent / tampered / expired).
  """
  def verify(conn) do
    max_age = Nexus.Config.session_max_age()

    with token when is_binary(token) <- cookie_value(conn),
         {:ok, %{tenant: t} = claims} when is_binary(t) and t != "" <-
           Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
      identity = Map.take(claims, [:tenant, :user, :roles, :scopes])
      if now() - (claims[:iat] || now()) > div(max_age, 2), do: {:ok, identity, :renew}, else: {:ok, identity}
    else
      _ -> :error
    end
  end

  @doc "Clear the session cookie (logout)."
  def clear(conn), do: Plug.Conn.delete_resp_cookie(conn, cookie(), path: "/")

  # ── internals ──
  defp cookie, do: Nexus.Config.session_cookie()

  defp cookie_value(conn) do
    conn = Plug.Conn.fetch_cookies(conn)
    conn.cookies[cookie()]
  end

  # https only unless this exact connection is already https (so a direct-TLS prod nexus works without
  # config, and an http dev nexus that turned session-secure off can round-trip the cookie).
  defp secure?(conn), do: Nexus.Config.session_secure?() or conn.scheme == :https

  defp now, do: System.system_time(:second)

  # The signing key: the deploy secret, or a stable per-boot random key in dev (never a hardcoded one).
  defp secret do
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

defmodule Nexus.Auth.Cookie do
  @moduledoc """
  Auth adapter backed by `Nexus.Auth.Session` — opt in with `config :nexus, auth: Nexus.Auth.Cookie`.
  A request with a valid session cookie authenticates as its identity; otherwise it is unauthenticated
  (401 for guarded routes, redirect-to-login is the provider phase's job). NOT the default adapter, so
  enabling sessions is an explicit, per-deployment choice.
  """
  @behaviour Nexus.Auth

  @impl true
  def authenticate(conn) do
    case Nexus.Auth.Session.verify(conn) do
      {:ok, identity} -> {:ok, identity}
      {:ok, identity, :renew} -> {:ok, identity}
      :error -> {:error, :no_session}
    end
  end
end
