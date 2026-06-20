defmodule Nexus.Auth.Accounts do
  @moduledoc """
  Native email/password identity — the half of our own auth (Guardian + BetterAuth) that WorkOS used
  to supply. Users live in a **SQLite table in the litestream-replicated `nexus.db`** (durable,
  volume-free), and a verified login issues a `Nexus.Auth.Session` cookie. No external IdP.

  ## Security
    * **Passwords are never stored** — only a PBKDF2-HMAC-SHA256 hash (`:crypto.pbkdf2_hmac`, OTP-native,
      210k iterations, per-user random salt), encoded `pbkdf2$<iter>$<salt>$<hash>`. Verify recomputes
      and compares in constant time (`Plug.Crypto.secure_compare`).
    * **Single-use, expiring tokens** for email verification + password reset — only their SHA-256 hash
      is stored, so a leaked DB yields no usable link.
    * Each user belongs to an **org** (the tenant). One nexus per org; the session carries the org.
  """
  alias Exqlite.Sqlite3

  @iterations 210_000
  @token_ttl 3600

  # ── schema (created idempotently in with_conn so any query is safe; call at boot to pre-warm) ────
  def ensure, do: with_conn(fn _ -> :ok end)

  # ── users ───────────────────────────────────────────────────────────────────────────────────────

  @doc "Create a user (+ a fresh org if none given). `{:ok, user}` | `{:error, :email_taken | :bad_email | :weak_password}`."
  def create(email, password, opts \\ []) do
    email = norm_email(email)

    cond do
      not valid_email?(email) -> {:error, :bad_email}
      byte_size(password) < 8 -> {:error, :weak_password}
      get_by_email(email) -> {:error, :email_taken}
      true ->
        ensure()
        id = "usr_" <> rand(8)
        org = opts[:org] || ("org_" <> rand(12))
        now = System.system_time(:second)

        exec("INSERT INTO users(id,email,pw_hash,org,name,verified,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7)",
          [id, email, hash_password(password), org, to_string(opts[:name] || ""), bool(opts[:verified]), now])

        {:ok, %{id: id, email: email, org: org, name: to_string(opts[:name] || ""), verified: !!opts[:verified], created_at: now}}
    end
  end

  @doc "Verify credentials. `{:ok, user}` | `:error`. Constant-time; same cost whether or not the email exists."
  def authenticate(email, password) do
    email = norm_email(email)

    case row("SELECT id,email,pw_hash,org,name,verified,created_at FROM users WHERE email=?1", [email]) do
      [id, em, ph, org, name, ver, created] ->
        if verify_password(password, ph),
          do: {:ok, %{id: id, email: em, org: org, name: name, verified: ver == 1, created_at: created}},
          else: :error

      _ ->
        # Spend a hash anyway so timing doesn't leak whether the email exists.
        _ = verify_password(password, hash_password("decoy"))
        :error
    end
  end

  def get_by_email(email), do: user_view(row("SELECT id,email,pw_hash,org,name,verified,created_at FROM users WHERE email=?1", [norm_email(email)]))
  def get(id), do: user_view(row("SELECT id,email,pw_hash,org,name,verified,created_at FROM users WHERE id=?1", [id]))

  def mark_verified(id), do: exec("UPDATE users SET verified=1 WHERE id=?1", [id])
  def set_password(id, password), do: exec("UPDATE users SET pw_hash=?1 WHERE id=?2", [hash_password(password), id])

  defp user_view([id, em, _ph, org, name, ver, created]), do: %{id: id, email: em, org: org, name: name, verified: ver == 1, created_at: created}
  defp user_view(_), do: nil

  # ── single-use email tokens (verify / reset) ────────────────────────────────────────────────────

  @doc "Mint a single-use token for `user_id` of `kind` (:verify | :reset). Returns the plaintext token (emailed once)."
  def mint_token(user_id, kind) do
    ensure()
    token = rand(24)
    exec("INSERT OR REPLACE INTO auth_tokens_otp(hash,user_id,kind,expires_at) VALUES(?1,?2,?3,?4)",
      [hash_token(token), user_id, to_string(kind), System.system_time(:second) + @token_ttl])
    token
  end

  @doc "Consume a token (single use). `{:ok, user_id}` | `:error` (unknown/expired/wrong kind)."
  def consume_token(token, kind) do
    h = hash_token(token)
    now = System.system_time(:second)
    kind_s = to_string(kind)

    case row("SELECT user_id,kind,expires_at FROM auth_tokens_otp WHERE hash=?1", [h]) do
      [uid, ^kind_s, exp] when exp > now ->
        exec("DELETE FROM auth_tokens_otp WHERE hash=?1", [h])
        {:ok, uid}

      _ ->
        :error
    end
  end

  # ── password hashing (PBKDF2-HMAC-SHA256, OTP-native, zero deps) ─────────────────────────────────

  def hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
    "pbkdf2$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(hash)}"
  end

  def verify_password(password, "pbkdf2$" <> rest) do
    case String.split(rest, "$") do
      [iter, salt64, hash64] ->
        salt = Base.decode64!(salt64)
        expected = Base.decode64!(hash64)
        actual = :crypto.pbkdf2_hmac(:sha256, password, salt, String.to_integer(iter), byte_size(expected))
        Plug.Crypto.secure_compare(actual, expected)

      _ ->
        false
    end
  end

  def verify_password(_, _), do: false

  # ── plumbing ─────────────────────────────────────────────────────────────────────────────────────
  defp norm_email(e), do: e |> to_string() |> String.trim() |> String.downcase()
  defp valid_email?(e), do: Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, e)
  defp rand(n), do: :crypto.strong_rand_bytes(n) |> Base.url_encode64(padding: false)
  defp hash_token(t), do: :crypto.hash(:sha256, t) |> Base.encode16(case: :lower)
  defp bool(true), do: 1
  defp bool(_), do: 0

  defp db_path, do: Application.get_env(:nexus, :cp_sqlite_path) || Nexus.Litestream.db_path()

  defp with_conn(fun) do
    path = db_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, c} = Sqlite3.open(path)
    Sqlite3.execute(c, "PRAGMA journal_mode=WAL")
    Sqlite3.execute(c, "PRAGMA busy_timeout=5000")
    Sqlite3.execute(c, "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT UNIQUE, pw_hash TEXT, org TEXT, name TEXT, verified INTEGER DEFAULT 0, created_at INTEGER)")
    Sqlite3.execute(c, "CREATE TABLE IF NOT EXISTS auth_tokens_otp (hash TEXT PRIMARY KEY, user_id TEXT, kind TEXT, expires_at INTEGER)")

    try do
      fun.(c)
    after
      Sqlite3.close(c)
    end
  end

  defp exec(sql, binds) do
    with_conn(fn c ->
      {:ok, s} = Sqlite3.prepare(c, sql)
      :ok = Sqlite3.bind(s, binds)
      :done = Sqlite3.step(c, s)
      Sqlite3.release(c, s)
    end)

    :ok
  end

  defp row(sql, binds) do
    with_conn(fn c ->
      {:ok, s} = Sqlite3.prepare(c, sql)
      :ok = Sqlite3.bind(s, binds)
      r = case Sqlite3.step(c, s) do
        {:row, vals} -> vals
        _ -> nil
      end
      Sqlite3.release(c, s)
      r
    end)
  end
end
