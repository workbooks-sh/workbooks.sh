defmodule Nexus.Auth.Native do
  @moduledoc """
  HTTP handlers for native email/password auth — signup / login / logout / email-verify / forgot /
  reset. A verified credential issues a `Nexus.Auth.Session` cookie (our own session, no WorkOS).
  Mounted by `Nexus.Server` under `/auth/*`. JSON in/out; email links go out via `Nexus.Auth.Email`.
  """
  import Plug.Conn
  require Logger
  alias Nexus.Auth.{Accounts, Email, Session}

  # POST /auth/signup {email, password, name}
  def signup(conn) do
    p = body(conn)

    # A pending invite places the new user in THAT org (with its role) instead of a fresh one.
    invite = Accounts.invite_for_email(to_string(p["email"]))
    opts = [name: p["name"]] ++ if(invite, do: [org: invite.org, role: invite.role], else: [])

    case Accounts.create(p["email"], to_string(p["password"]), opts) do
      {:ok, user} ->
        if invite, do: Accounts.consume_invite(user.email)
        send_verification(user)
        conn |> Session.issue(identity(user)) |> json(200, %{ok: true, user: pub(user)})

      {:error, reason} ->
        json(conn, 422, %{error: error_msg(reason)})
    end
  end

  # POST /auth/login {email, password}
  def login(conn) do
    p = body(conn)

    case Accounts.authenticate(to_string(p["email"]), to_string(p["password"])) do
      {:ok, user} -> conn |> Session.issue(identity(user)) |> json(200, %{ok: true, user: pub(user)})
      :error -> json(conn, 401, %{error: "Invalid email or password"})
    end
  end

  # POST /auth/logout
  def logout(conn), do: conn |> Session.clear() |> json(200, %{ok: true})

  # GET /auth/verify?token=… — consume the link, mark verified, land on the dashboard.
  def verify(conn) do
    conn = fetch_query_params(conn)

    case Accounts.consume_token(conn.query_params["token"] || "", :verify) do
      {:ok, uid} ->
        Accounts.mark_verified(uid)
        conn |> put_resp_header("location", app_url()) |> send_resp(302, "")

      :error ->
        json(conn, 400, %{error: "This verification link is invalid or has expired."})
    end
  end

  # POST /auth/forgot {email} — always 200 (no account enumeration).
  def forgot(conn) do
    p = body(conn)

    case Accounts.get_by_email(to_string(p["email"])) do
      nil -> :ok
      user -> Email.send_reset(user.email, link("/auth/reset?token=" <> Accounts.mint_token(user.id, :reset)))
    end

    json(conn, 200, %{ok: true})
  end

  # POST /auth/reset {token, password} — consume the link, set the new password, sign in.
  def reset(conn) do
    p = body(conn)

    with {:ok, uid} <- Accounts.consume_token(to_string(p["token"]), :reset),
         pw when byte_size(pw) >= 8 <- to_string(p["password"]) do
      Accounts.set_password(uid, pw)
      conn |> Session.issue(identity(Accounts.get(uid))) |> json(200, %{ok: true})
    else
      :error -> json(conn, 400, %{error: "This reset link is invalid or has expired."})
      _ -> json(conn, 422, %{error: "Password must be at least 8 characters."})
    end
  end

  # ── helpers ──
  defp send_verification(user),
    do: Email.send_verification(user.email, link("/auth/verify?token=" <> Accounts.mint_token(user.id, :verify)))

  # The session identity carries `:roles` so server-side authority (Nexus.Auth.role/1) needs no DB hit.
  # `u` from create/invite already has `:role`; `u` from a login lookup doesn't, so fall back to the DB.
  defp identity(u), do: %{tenant: u.org, user: u.id, email: u.email, name: u.name, roles: List.wrap(Map.get(u, :role) || Accounts.role(u.id))}
  defp pub(u), do: %{id: u.id, email: u.email, name: u.name, verified: u.verified, org: u.org}

  defp error_msg(:email_taken), do: "That email is already registered."
  defp error_msg(:bad_email), do: "Enter a valid email address."
  defp error_msg(:weak_password), do: "Password must be at least 8 characters."
  defp error_msg(other), do: to_string(other)

  # Absolute base for email links — deploy injection (the public URL), like WB_DATA/PORT.
  defp base, do: System.get_env("WB_BASE_URL") || "https://workbooks.sh"
  defp app_url, do: base() <> "/cloud/"
  defp link(path), do: base() <> path

  defp body(conn) do
    case read_body(conn) do
      {:ok, raw, _} -> (raw != "" && Jason.decode(raw)) || {:ok, %{}}
      _ -> {:ok, %{}}
    end
    |> case do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp json(conn, status, map),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))
end
