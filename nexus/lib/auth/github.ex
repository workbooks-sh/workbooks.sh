defmodule Nexus.Auth.Github do
  @moduledoc """
  "Sign in with GitHub" — the user-authorization (OAuth2) half of our GitHub App. It uses the SAME App
  credentials already injected on the machine (`GITHUB_APP_CLIENT_ID` / `GITHUB_APP_CLIENT_SECRET`, read
  via `Nexus.Secrets`) — no separate OAuth app. GitHub is OAuth2, not OIDC: there is no `id_token`, so we
  exchange the `code` for an access token, then read `/user` (+ `/user/emails`) to resolve the person,
  find-or-create our own account (`Nexus.Auth.Accounts`), and issue our native session
  (`Nexus.Auth.Session`) — identical to a password login from there on.

  Routes: `GET /auth/github/login` → `GET /auth/github/callback`. CSRF is a signed `state` cookie echoed
  back by GitHub. Register the callback URL `<origin>/auth/github/callback` in the GitHub App's settings.
  """
  import Plug.Conn
  alias Nexus.Auth.{Accounts, Session}

  @authorize "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"
  @api "https://api.github.com"
  @state_cookie "wb_gh_state"
  @salt "wb_gh_oauth_v1"
  @ttl 600

  @doc "Is GitHub sign-in available (the App's user-auth client id is present)?"
  def configured?, do: is_binary(Nexus.Secrets.get("GITHUB_APP_CLIENT_ID"))

  @doc "GET /auth/github/login — set the CSRF state cookie and 302 to GitHub's authorize endpoint."
  def login(conn) do
    if configured?() do
      conn = fetch_query_params(conn)
      state = rand()

      url =
        @authorize <>
          "?" <>
          URI.encode_query(%{
            "client_id" => Nexus.Secrets.get("GITHUB_APP_CLIENT_ID"),
            "redirect_uri" => redirect_uri(conn),
            "scope" => "read:user user:email",
            "state" => state,
            "allow_signup" => "true"
          })

      # carry the device flow (?device=&cb=) THROUGH the OAuth round-trip in the
      # signed state cookie, so the callback returns to the caller instead of the
      # dashboard (the AutoPoet 'Sign in with Workbooks' path).
      conn
      |> put_state(state, conn.query_params["device"], conn.query_params["cb"])
      |> put_resp_header("location", url)
      |> send_resp(302, "")
    else
      send_resp(conn, 404, "github sign-in not configured")
    end
  end

  @doc "GET /auth/github/callback — verify state, exchange code, resolve the user, issue a session."
  def callback(conn) do
    conn = conn |> fetch_query_params() |> fetch_cookies()
    p = conn.query_params

    with {:ok, %{s: want} = st} <- verify_state(conn),
         code when is_binary(code) and code != "" <- p["code"],
         state when is_binary(state) <- p["state"],
         true <- Plug.Crypto.secure_compare(state, want),
         {:ok, token} <- exchange(code, redirect_uri(conn)),
         {:ok, profile} <- fetch_user(token),
         {:ok, identity} <- provision(profile) do
      conn
      |> clear_state()
      |> Session.issue(identity)
      |> put_resp_header("location", after_login_location(st))
      |> send_resp(302, "")
    else
      _ -> conn |> clear_state() |> put_resp_header("location", "/login/?error=github") |> send_resp(302, "")
    end
  end

  # device flow → back to the login island with ?device&cb so its on-load mint
  # fires (session now valid); otherwise the dashboard.
  defp after_login_location(%{d: d, cb: cb}) when is_binary(d) and d != "" and is_binary(cb) and cb != "",
    do: "/login/?" <> URI.encode_query(%{"device" => d, "cb" => cb})

  defp after_login_location(_), do: "/cloud/"

  # ── OAuth steps ──

  # code → access token (form POST; GitHub returns JSON when we Accept it).
  defp exchange(code, redirect) do
    body =
      URI.encode_query(%{
        "client_id" => Nexus.Secrets.get("GITHUB_APP_CLIENT_ID"),
        "client_secret" => Nexus.Secrets.get("GITHUB_APP_CLIENT_SECRET"),
        "code" => code,
        "redirect_uri" => redirect
      })

    case http(:post, @token_url, [{~c"accept", ~c"application/json"}], ~c"application/x-www-form-urlencoded", body) do
      {:ok, %{"access_token" => t}} when is_binary(t) and t != "" -> {:ok, t}
      _ -> :error
    end
  end

  # access token → {email, name, login}. GitHub may hide the email on /user, so fall back to /user/emails.
  defp fetch_user(token) do
    case gh_get("/user", token) do
      {:ok, %{"login" => login} = u} ->
        email = u["email"] || primary_email(token)
        if is_binary(email) and email != "",
          do: {:ok, %{email: email, name: u["name"] || login, avatar: u["avatar_url"]}},
          else: :error

      _ ->
        :error
    end
  end

  defp primary_email(token) do
    case gh_get("/user/emails", token) do
      {:ok, list} when is_list(list) ->
        Enum.find_value(list, fn e -> if e["primary"] && e["verified"], do: e["email"] end)

      _ ->
        nil
    end
  end

  # find-or-create our account for this GitHub identity → the session identity (with roles).
  # An EXISTING account always logs in; creating a NEW account obeys the same signup gate as
  # /auth/signup — so a control plane with no allowlist won't mint an org for any GitHub user, and an
  # allowlist, when set, is honoured here too (this path previously bypassed both — open-signup vector).
  defp provision(%{email: email, name: name} = p) do
    avatar = p[:avatar]

    user =
      Accounts.get_by_email(email) ||
        if(signup_allowed?(email), do: create_oauth_user(email, name, avatar), else: nil)

    case user do
      %{org: org, id: id} ->
        # backfill name/avatar for an existing (possibly nameless) account
        Accounts.update_profile(id, name, avatar)
        {:ok, %{tenant: org, user: id, email: email, name: name, avatar: avatar, roles: List.wrap(Accounts.role(id))}}

      _ ->
        :error
    end
  end

  # Same gate as native /auth/signup: signups must be open (fail-closed on a broker-holding control
  # plane) AND the email must satisfy the allowlist when one is set.
  defp signup_allowed?(email), do: Nexus.Config.signups_open?() and Nexus.Config.login_permitted?(email)

  defp create_oauth_user(email, name, avatar) do
    # OAuth users have no password they use; seed a strong random one (>=8 bytes) and mark verified
    # (GitHub already verified the email).
    case Accounts.create(email, rand() <> rand(), name: name, verified: true, avatar: avatar) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  # ── state cookie (CSRF) ──

  defp put_state(conn, state, device \\ nil, cb \\ nil) do
    signed = Plug.Crypto.sign(secret(), @salt, %{s: state, d: device, cb: cb, iat: System.os_time(:second)})

    put_resp_cookie(conn, @state_cookie, signed,
      http_only: true,
      same_site: "Lax",
      secure: secure?(conn),
      max_age: @ttl,
      path: "/"
    )
  end

  # returns the FULL signed payload (%{s, d, cb}) so the callback can honor the
  # carried device flow, not just the CSRF token.
  defp verify_state(conn) do
    with token when is_binary(token) <- conn.cookies[@state_cookie],
         {:ok, %{s: _} = payload} <- Plug.Crypto.verify(secret(), @salt, token, max_age: @ttl) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp clear_state(conn), do: delete_resp_cookie(conn, @state_cookie, path: "/")

  # ── helpers ──

  defp redirect_uri(conn), do: origin(conn) <> "/auth/github/callback"

  # The public origin — proxy-aware. Behind Fly's TLS-terminating proxy `conn.scheme` is `http`, so we
  # honor `x-forwarded-proto` (and `-host`); otherwise GitHub gets an http redirect_uri it rejects, and
  # the login/callback URIs wouldn't match. Falls back to the conn when there's no proxy (local dev).
  defp origin(conn) do
    scheme = forwarded(conn, "x-forwarded-proto") || to_string(conn.scheme)
    host = forwarded(conn, "x-forwarded-host") || host_with_port(conn)
    "#{scheme}://#{host}"
  end

  defp host_with_port(conn) do
    if conn.port in [80, 443, nil], do: conn.host, else: "#{conn.host}:#{conn.port}"
  end

  defp forwarded(conn, header) do
    case get_req_header(conn, header) do
      [v | _] when is_binary(v) and v != "" -> v |> String.split(",") |> hd() |> String.trim()
      _ -> nil
    end
  end

  defp gh_get(path, token) do
    http(:get, @api <> path, [{~c"authorization", String.to_charlist("Bearer #{token}")},
      {~c"accept", ~c"application/vnd.github+json"}], nil, nil)
  end

  # Thin :httpc JSON wrapper (mirrors Nexus.GitHub's transport). Always sends a user-agent (GitHub 403s
  # without one). Returns {:ok, decoded} on 2xx, else :error.
  defp http(method, url, headers, ctype, body) do
    url = String.to_charlist(url)
    headers = [{~c"user-agent", ~c"workbooks-nexus"} | headers]

    request =
      case method do
        :get -> {url, headers}
        _ -> {url, headers, to_charlist(ctype), body}
      end

    case :httpc.request(method, request, [{:timeout, 15_000}] ++ Nexus.Net.tls_opts(), body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} when status in 200..299 ->
        {:ok, (resp == "" && %{}) || Jason.decode!(resp)}

      _ ->
        :error
    end
  end

  defp rand, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp secure?(conn), do: Nexus.Config.session_secure?() or conn.scheme == :https

  defp secret do
    case Nexus.Secrets.get("WB_SESSION_SECRET") do
      v when is_binary(v) and byte_size(v) >= 16 -> v
      _ -> String.duplicate("wb-dev-oauth-state-key-not-for-prod", 2)
    end
  end
end
