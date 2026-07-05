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
        # The creator of a NEW org is its owner; someone joining an existing org (an invite) gets the
        # invited role (default member).
        role = canon_role(opts[:role] || if(opts[:org], do: "member", else: "owner"))
        now = System.system_time(:second)

        exec("INSERT INTO users(id,email,pw_hash,org,name,verified,created_at,role,avatar) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
          [id, email, hash_password(password), org, to_string(opts[:name] || ""), bool(opts[:verified]), now, role, opts[:avatar]])

        {:ok, %{id: id, email: email, org: org, name: to_string(opts[:name] || ""), role: role, verified: !!opts[:verified], created_at: now, avatar: opts[:avatar]}}
    end
  end

  @doc "Verify credentials. `{:ok, user}` | `:error`. Constant-time; same cost whether or not the email exists."
  def authenticate(email, password) do
    email = norm_email(email)

    case row("SELECT id,email,pw_hash,org,name,verified,created_at,avatar FROM users WHERE email=?1", [email]) do
      [id, em, ph, org, name, ver, created, avatar] ->
        if verify_password(password, ph),
          do: {:ok, %{id: id, email: em, org: org, name: name, verified: ver == 1, created_at: created, avatar: avatar}},
          else: :error

      _ ->
        # Spend a hash anyway so timing doesn't leak whether the email exists.
        _ = verify_password(password, hash_password("decoy"))
        :error
    end
  end

  def get_by_email(email), do: user_view(row("SELECT id,email,pw_hash,org,name,verified,created_at,avatar FROM users WHERE email=?1", [norm_email(email)]))
  def get(id), do: user_view(row("SELECT id,email,pw_hash,org,name,verified,created_at,avatar FROM users WHERE id=?1", [id]))

  @doc "A user's role by id (owner/admin/member/viewer), or nil if unknown."
  def role(id) do
    ensure()

    case row("SELECT role FROM users WHERE id=?1", [id]) do
      [r] when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  def mark_verified(id), do: exec("UPDATE users SET verified=1 WHERE id=?1", [id])
  def set_password(id, password), do: exec("UPDATE users SET pw_hash=?1 WHERE id=?2", [hash_password(password), id])

  @doc """
  This nexus's canonical org — the founding owner's org (one nexus per org). The first user to sign up
  with no invite becomes the `owner` of a fresh org; that org IS the nexus. Used by `Nexus.Secrets` to
  read nexus-scoped secrets from the SAME org the dashboard writes them to. `nil` before anyone signs up.
  """
  def nexus_org do
    ensure()

    case row("SELECT org FROM users WHERE role='owner' ORDER BY created_at ASC LIMIT 1", []) do
      [org] when is_binary(org) and org != "" -> org
      _ -> nil
    end
  end

  # ── org members ─────────────────────────────────────────────────────────────────────────────────
  @doc "Everyone in `org` — the org roster. `[%{id, name, email, role, created_at}]`, owners first."
  def list_org(org) do
    ensure()
    rows("SELECT id,email,name,role,created_at FROM users WHERE org=?1", [org])
    |> Enum.map(fn [id, em, name, role, created] ->
      %{id: id, email: em, name: to_string(name), role: role || "member", created_at: created}
    end)
    |> Enum.sort_by(fn m -> {if(m.role == "owner", do: 0, else: 1), String.downcase(m.name)} end)
  end

  # Normalize a role to the canonical lowercase set; an unknown/garbage role ⇒ least privilege (viewer),
  # never silently a higher tier. This is what makes the lowercase `role='owner'` comparisons safe — a
  # mis-cased "Owner" or an injected "superadmin" can no longer be stored, so they can't slip past the
  # last-owner guard or be surfaced as authority. (red-team wb-91gi; hardens the wb-wbm6 invite path too.)
  @roles ~w(owner admin member viewer)
  def canon_role(role) do
    r = role |> to_string() |> String.downcase()
    if r in @roles, do: r, else: "viewer"
  end

  @rank %{"owner" => 3, "admin" => 2, "member" => 1, "viewer" => 0}
  @doc "Numeric rank of a role (owner=3 … viewer=0) for privilege comparisons. Unknown ⇒ 0."
  def rank(role), do: Map.get(@rank, canon_role(role), 0)

  @doc "Remove a member from `org` (no-op if they're not in it, or are the org's last owner)."
  def remove_member(org, id) do
    case row("SELECT role FROM users WHERE id=?1 AND org=?2", [id, org]) do
      ["owner"] ->
        # never strand an org with zero owners
        case rows("SELECT id FROM users WHERE org=?1 AND role='owner'", [org]) do
          [_only] -> {:error, :last_owner}
          _ -> exec("DELETE FROM users WHERE id=?1 AND org=?2", [id, org])
        end

      nil -> {:error, :not_found}
      _ -> exec("DELETE FROM users WHERE id=?1 AND org=?2", [id, org])
    end
  end

  # ── invitations ─────────────────────────────────────────────────────────────────────────────────
  @doc "Invite `email` to `org` with `role`. Returns the pending invite. Re-inviting refreshes it."
  def invite(org, email, role \\ "member", invited_by \\ nil) do
    ensure()
    email = norm_email(email)
    if not valid_email?(email), do: {:error, :bad_email}, else: invite_put(org, email, role, invited_by)
  end

  defp invite_put(org, email, role, invited_by) do
    exec("DELETE FROM org_invites WHERE org=?1 AND email=?2", [org, email])
    id = "inv_" <> rand(8)
    role = canon_role(role || "member")
    exec("INSERT INTO org_invites(id,org,email,role,invited_by,created_at) VALUES(?1,?2,?3,?4,?5,?6)",
      [id, org, email, role, invited_by, System.system_time(:second)])
    {:ok, %{id: id, org: org, email: email, role: role}}
  end

  @doc "Pending invites for `org`. `[%{id, email, role}]`."
  def list_invites(org) do
    ensure()
    rows("SELECT id,email,role FROM org_invites WHERE org=?1 ORDER BY created_at DESC", [org])
    |> Enum.map(fn [id, em, role] -> %{id: id, email: em, role: role || "member"} end)
  end

  @doc "Revoke a pending invite (scoped to its org)."
  def revoke_invite(org, id), do: exec("DELETE FROM org_invites WHERE id=?1 AND org=?2", [id, org])

  @doc "A pending invite for `email`, or nil — consulted at signup so an invitee joins their org."
  def invite_for_email(email) do
    case row("SELECT org,role FROM org_invites WHERE email=?1 ORDER BY created_at DESC LIMIT 1", [norm_email(email)]) do
      [org, role] -> %{org: org, role: role || "member"}
      _ -> nil
    end
  end

  @doc "Consume (delete) any invite for `email` — called once the invitee has signed up."
  def consume_invite(email), do: exec("DELETE FROM org_invites WHERE email=?1", [norm_email(email)])

  defp user_view([id, em, _ph, org, name, ver, created, avatar]), do: %{id: id, email: em, org: org, name: name, verified: ver == 1, created_at: created, avatar: avatar}
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

  defp db_path, do: Nexus.Paths.db_path()

  defp with_conn(fun) do
    path = db_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, c} = Sqlite3.open(path)
    Sqlite3.execute(c, "PRAGMA journal_mode=WAL")
    Sqlite3.execute(c, "PRAGMA busy_timeout=5000")
    Sqlite3.execute(c, "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT UNIQUE, pw_hash TEXT, org TEXT, name TEXT, verified INTEGER DEFAULT 0, created_at INTEGER, role TEXT DEFAULT 'owner')")
    # Existing dbs predate the role column — add it idempotently (ignores "duplicate column").
    Sqlite3.execute(c, "ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'owner'")
    # avatar (profile picture URL from GitHub/Google) — synced into desktop onboarding.
    Sqlite3.execute(c, "ALTER TABLE users ADD COLUMN avatar TEXT")
    Sqlite3.execute(c, "CREATE TABLE IF NOT EXISTS auth_tokens_otp (hash TEXT PRIMARY KEY, user_id TEXT, kind TEXT, expires_at INTEGER)")
    # Org invitations — a teammate is invited by email; on signup the invite places them in the org
    # (with its role) instead of a fresh org. Pending until accepted or revoked.
    Sqlite3.execute(c, "CREATE TABLE IF NOT EXISTS org_invites (id TEXT PRIMARY KEY, org TEXT, email TEXT, role TEXT, invited_by TEXT, created_at INTEGER)")

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

  defp rows(sql, binds) do
    with_conn(fn c ->
      {:ok, s} = Sqlite3.prepare(c, sql)
      :ok = Sqlite3.bind(s, binds)
      {:ok, all} = Sqlite3.fetch_all(c, s)
      Sqlite3.release(c, s)
      all
    end)
  end
end
