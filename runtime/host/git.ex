defmodule Workbooks.Git do
  @moduledoc """
  Git-backed Workbook store — the versioned source of truth (the SQLite control
  plane stays as the fast index). The runtime's data is just files (Org sources +
  Bundles), so making the per-tenant data root a git repo buys history, diff, and
  rollback for free. Thin wrapper over the `git` CLI, same discipline as the
  Package Manager shelling to cargo/bun. See docs/GIT.org.

  Phase 2 (here): the auth identity bridge. `save/3` takes an identity (the
  authenticated tenant + author from `conn.assigns`), commits *as* that identity
  (GIT_AUTHOR_NAME/EMAIL), and ensures a per-tenant Ed25519 keypair — the future
  Radicle DID basis. Radicle federation (publish/clone by DID) is a later phase.
  """

  @doc "Per-tenant repo path under WB_DATA (default tmp/data)."
  def repo_path(tenant), do: Path.join([System.get_env("WB_DATA", "tmp/data"), to_string(tenant)])

  @doc """
  Build a commit identity from the authenticated tenant. `author` defaults to the
  tenant; the email is `<tenant>@workbooks.local` — git's attribution = auth's WHO.
  """
  def identity(tenant, author \\ nil) do
    t = to_string(tenant)
    %{tenant: t, author: to_string(author || t), email: "#{t}@workbooks.local"}
  end

  @doc "Idempotently init the tenant's repo and its Ed25519 signing keypair."
  def ensure_repo(tenant) do
    dir = repo_path(tenant)

    unless File.dir?(Path.join(dir, ".git")) do
      File.mkdir_p!(dir)
      git(dir, ["init", "-q"])
    end

    # The signing key NEVER enters version control — the ledger's whole
    # attribution model rests on the private half staying host-only. Ignore the
    # entire .workbooks/ keystore (git AND jj-colocate both honor .gitignore).
    ensure_gitignore(dir)
    ensure_keypair(dir, tenant)
    dir
  end

  # Personal/session data never enters version control by default — the automated
  # public/private ignore. The full set is owned by `Workbooks.Private` (one
  # boundary for git + bundle + library), so it can't drift between egress paths.
  defp ensure_gitignore(dir) do
    gi = Path.join(dir, ".gitignore")
    have = if File.exists?(gi), do: File.read!(gi), else: ""
    missing = Enum.reject(Workbooks.Private.gitignore_lines(), &String.contains?(have, &1))
    unless missing == [], do: File.write!(gi, have <> Enum.join(missing, "\n") <> "\n")
  end

  @doc """
  Generate+store a per-tenant Ed25519 keypair (`:crypto`) under `.workbooks/` —
  the signing-key basis for the tenant's DID. Untracked (the private half never
  gets committed). Idempotent. Returns the public key (raw).

  DURABILITY (the fix for ephemeral deploys): the keystore lives on the
  container fs, which is wiped on every redeploy — so without a persisted seed a
  redeploy MINTS A NEW DID and breaks every prior signature/ledger. For the
  primary tenant we restore the keypair DETERMINISTICALLY from a persisted 32-byte
  seed (`WB_SIGNING_KEY`, a Fly secret) so the DID is stable across deploys. Other
  tenants' keys will come from the BYOD storage backend (next focus); until then
  they regenerate, which is fine in single-tenant mode.
  """
  def ensure_keypair(dir, tenant) do
    path = key_path(dir, tenant)

    unless File.exists?(path) do
      {pub, priv} = restore_or_generate(tenant)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Base.encode16(priv, case: :lower))
      File.write!(path <> ".pub", Base.encode16(pub, case: :lower))
    end

    (path <> ".pub") |> File.read!() |> Base.decode16!(case: :lower)
  end

  # Restore the keypair from a persisted seed (stable DID across deploys) or mint
  # a fresh one. `WB_SIGNING_KEY` = base64 of the 32-byte Ed25519 seed, held as a
  # Fly secret; applies to the primary tenant (`WB_PRIMARY_TENANT`, default "dev").
  defp restore_or_generate(tenant) do
    case persisted_seed(tenant) do
      {:ok, seed} -> {pub, _} = :crypto.generate_key(:eddsa, :ed25519, seed); {pub, seed}
      :none -> :crypto.generate_key(:eddsa, :ed25519)
    end
  end

  defp persisted_seed(tenant) do
    primary = System.get_env("WB_PRIMARY_TENANT", "dev")

    with true <- to_string(tenant) == primary,
         k when is_binary(k) and k != "" <- System.get_env("WB_SIGNING_KEY"),
         {:ok, seed} when byte_size(seed) == 32 <- Base.decode64(k) do
      {:ok, seed}
    else
      _ -> :none
    end
  end

  @doc """
  The tenant's signing identity as a real `did:key` — the Ed25519 public key with
  the `0xed01` multicodec prefix, base58btc-encoded, multibase-tagged `z`. The
  same `did:key:z6Mk…` form Radicle and the W3C DID spec use (interoperable, not
  a bespoke hex form).
  """
  def did(tenant) do
    pub = ensure_keypair(repo_path(tenant), tenant)
    "did:key:z" <> base58btc(<<0xED, 0x01>> <> pub)
  end

  @doc """
  Sign bytes with the tenant's Ed25519 private key (the did:key half) — the
  ATTRIBUTABLE half of the signed ledger. Returns the raw signature.
  """
  def sign(tenant, msg) do
    dir = repo_path(tenant)
    ensure_keypair(dir, tenant)
    priv = key_path(dir, tenant) |> File.read!() |> Base.decode16!(case: :lower)
    :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])
  end

  @doc "Verify a signature over `msg` against a `did:key` (decodes the pubkey from the DID)."
  def verify_sig(did, msg, sig) do
    :crypto.verify(:eddsa, :none, msg, sig, [pub_of_did(did), :ed25519])
  rescue
    _ -> false
  end

  # did:key:z<base58(0xed01 || pub)> → the raw 32-byte Ed25519 public key.
  defp pub_of_did("did:key:z" <> b58) do
    <<0xED, 0x01, pub::binary-size(32)>> = decode58(b58)
    pub
  end

  # Base58btc (Bitcoin alphabet) — the multibase `z` encoding for did:key.
  @b58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  defp base58btc(bin) do
    String.duplicate("1", leading_zeros(bin, 0)) <> encode58(:binary.decode_unsigned(bin), [])
  end

  defp encode58(0, acc), do: List.to_string(acc)
  defp encode58(n, acc), do: encode58(div(n, 58), [Enum.at(@b58, rem(n, 58)) | acc])

  defp decode58(str) do
    n = str |> String.to_charlist() |> Enum.reduce(0, fn ch, acc -> acc * 58 + Enum.find_index(@b58, &(&1 == ch)) end)
    zeros = str |> String.to_charlist() |> Enum.take_while(&(&1 == ?1)) |> length()
    :binary.copy(<<0>>, zeros) <> :binary.encode_unsigned(n)
  end

  defp leading_zeros(<<0, rest::binary>>, n), do: leading_zeros(rest, n + 1)
  defp leading_zeros(_, n), do: n

  @doc """
  Store a Workbook's Org source as `<name>.org` and commit it *as the given
  identity*. `id` is a `%{tenant, author, email}` map (see `identity/2`); the
  commit's author/committer is set from it. Returns the commit sha (or :nochange).
  """
  def save(%{tenant: tenant} = id, name, org) do
    dir = ensure_repo(tenant)
    File.write!(Path.join(dir, "#{name}.org"), org)
    git(dir, ["add", "#{name}.org"])

    case git(dir, ["commit", "-q", "-m", "deploy #{name}"], env: commit_env(id)) do
      {_, 0} -> {out, _} = git(dir, ["rev-parse", "HEAD"]); {:ok, String.trim(out)}
      {_, _} -> :nochange
    end
  end

  @doc """
  HOST-BROKERED commit + push for an agent's working dir (wb-9ja). The keeper
  agent (Waldo) used to `git add/commit/push` via the deleted native `run` hatch;
  now it calls the agent `git` TOOL, and THIS host function runs git on its behalf.

  This is HOST code operating its OWN repos (the tenant's data repo). It is not the
  agent executing native code — the agent supplies only a commit message; the host
  decides the exact command line (`add -A` → commit → push origin). `dir` is the
  agent's workdir (= the tenant repo); `tenant` sets the commit identity. Pushes to
  `origin` only when that remote exists (best-effort: a missing remote / network
  failure is reported, never raised). Returns:
    * `{:ok, info}`        — committed (sha) and, if pushable, pushed
    * `{:nochange, dir}`   — nothing staged to commit
    * `{:error, reason}`
  """
  def commit_and_push(dir, message, tenant) when is_binary(dir) do
    id = identity(tenant)
    # Hooks disabled so a global bd hook can't touch a non-beads repo (same as
    # ensure_commit). add -A is safe: the auto-.gitignore (Workbooks.Private)
    # excludes session/secret data, so a bulk add can't sweep in the signing key.
    ensure_gitignore(dir)
    git(dir, ["add", "-A"])

    case git(dir, ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message], env: commit_env(id)) do
      {_, 0} ->
        {sha, _} = git(dir, ["rev-parse", "--short", "HEAD"])
        # COMMIT ⇒ PUBLISH, atomically (the lander shipped blogs that were
        # committed but 404 because the run died before a separate publish step).
        # Mirroring content/** + blog/** to the live site dir here means
        # "committed" always implies "live" — a run can die any time after the
        # commit and the page still reflects the repo.
        pub =
          case Workbooks.SitePublish.publish(dir, tenant) do
            {:ok, n} when n > 0 -> " (published #{n})"
            _ -> ""
          end

        {:ok, String.trim(sha) <> maybe_push(dir) <> pub}

      {_, _} ->
        {:nochange, dir}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Push HEAD to origin when an origin remote is configured; otherwise the commit
  # stands locally (the public mirror is wired separately via mirror/3 or the
  # deploy operator). Never raises — a wedged/absent network is just reported.
  defp maybe_push(dir) do
    if has_remote?(dir, "origin") do
      case git(dir, ["push", "origin", "HEAD"]) do
        {_, 0} -> " (pushed)"
        {out, _} -> " (push failed: #{String.slice(String.trim(out), 0, 120)})"
      end
    else
      " (committed; no origin remote to push)"
    end
  end

  @doc "Author (`name <email>`) of the tenant repo's latest commit."
  def author(tenant) do
    {out, _} = git(repo_path(tenant), ["log", "-1", "--pretty=format:%an <%ae>"])
    String.trim(out)
  end

  defp key_path(dir, tenant), do: Path.join([dir, ".workbooks", "#{tenant}.ed25519"])

  defp commit_env(%{author: author, email: email}) do
    [
      {"GIT_AUTHOR_NAME", author},
      {"GIT_AUTHOR_EMAIL", email},
      {"GIT_COMMITTER_NAME", author},
      {"GIT_COMMITTER_EMAIL", email}
    ]
  end

  @doc "Commit history as a list of `\"<sha> <subject>\"` lines (newest first)."
  def log(tenant) do
    case git(repo_path(tenant), ["log", "--oneline"]) do
      {out, 0} -> out |> String.split("\n", trim: true)
      _ -> []
    end
  end

  @doc "Structured commit history `[%{sha, ts, author, msg}]` newest-first (ts = unix seconds)."
  def log_entries(tenant) do
    case git(repo_path(tenant), ["log", "--format=%h%x09%ct%x09%an%x09%s"]) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [sha, ts, author, msg] <- [String.split(line, "\t", parts: 4)] do
          %{sha: sha, ts: String.to_integer(ts), author: author, msg: msg}
        end

      _ ->
        []
    end
  end

  @doc "Diff of the last commit against its parent (what the latest deploy changed)."
  def diff(tenant) do
    {out, _} = git(repo_path(tenant), ["diff", "HEAD~1", "HEAD"])
    out
  end

  defp git(dir, args, opts \\ []),
    do: System.cmd("git", args, [cd: dir, stderr_to_stdout: true] ++ opts)

  # --- Radicle federation (GIT.org phase 3) ---------------------------------
  #
  # Thin wrapper over the `rad` CLI — P2P git, no central server, DID identity.
  # Same discipline as the git wrapper: we orchestrate, rad owns the protocol.
  #
  # Identity constraint (UPSTREAM rad limitation, not our gap): rad keys are
  # per-*device* (one Ed25519 key per local `rad` profile = the node's DID). The
  # per-tenant keypair from `ensure_keypair/2` is a separate signing identity, and
  # the `rad` CLI has no command to import an external key as a repo delegate — so
  # tenant-keypair == Radicle-delegate-DID requires a feature `rad` doesn't expose
  # yet (multi-key). Until rad adds it, a publish is delegated by the node DID and
  # org members map to delegates via `add_delegate/2` (which DOES work). This is a
  # missing upstream feature, not unfinished code on our side.

  @doc "The local rad node's device DID, creating the rad profile if absent. Idempotent."
  def ensure_rad_profile do
    case System.cmd("rad", ["self", "--did"], stderr_to_stdout: true) do
      {out, 0} ->
        String.trim(out)

      _ ->
        System.cmd("rad", ["auth", "--alias", "workbooks-runtime"], env: rad_env(), stderr_to_stdout: true)
        {out, _} = System.cmd("rad", ["self", "--did"], stderr_to_stdout: true)
        String.trim(out)
    end
  end

  # ── source rail: mirror to ANY git host ──────────────────────────────────────
  # The rail is plain `git push` to a remote URL — host-agnostic (GitHub, GitLab,
  # Gitea, self-hosted, Radicle). The host stays provider-free; only first-time
  # repo PROVISIONING varies, and that leans on whichever forge CLI is on PATH
  # (gh/glab/tea — the toolkit layer), never hardcoded. Sits alongside `publish`
  # (Radicle) since both are "push this repo to a federation/host."
  @forge_cli %{"github" => "gh", "gitlab" => "glab", "gitea" => "tea"}

  @doc "Mirror the tenant repo to an explicit remote URL — works with every git host."
  def mirror(tenant, remote_url, opts \\ []) when is_binary(remote_url) do
    dir = ensure_repo(tenant)
    ensure_commit(dir, tenant)
    remote = opts[:remote] || "origin"
    git(dir, ["remote", "remove", remote])
    git(dir, ["remote", "add", remote, remote_url])

    case git(dir, ["push", remote, "HEAD"]) do
      {_, 0} -> {:ok, remote_url}
      {out, _} -> {:error, out}
    end
  end

  @doc """
  Push the tenant repo to a forge: push an existing remote, else PROVISION a new
  repo via the named (or first-present) forge CLI, then push. opts: :forge, :repo,
  :visibility ("private"), :remote. {:ok, url} | {:skip, reason} | {:error, out}.
  """
  def forge_push(tenant, opts \\ []) do
    dir = ensure_repo(tenant)
    ensure_commit(dir, tenant)
    remote = opts[:remote] || "origin"

    if has_remote?(dir, remote) do
      case git(dir, ["push", remote, "HEAD"]) do
        {_, 0} -> {:ok, remote_url(dir, remote)}
        {out, _} -> {:error, out}
      end
    else
      provision(opts[:forge] || detect_forge(), dir, remote, opts)
    end
  end

  @doc "Which forge CLI is available (the toolkit), or nil. github > gitlab > gitea."
  def detect_forge, do: Enum.find(~w(github gitlab gitea), &has?(@forge_cli[&1]))

  @doc "Delete a provisioned repo (test cleanup / retired mirror) via its forge CLI."
  def forge_delete("github", repo), do: System.cmd("gh", ["repo", "delete", repo, "--yes"], stderr_to_stdout: true)
  def forge_delete("gitlab", repo), do: System.cmd("glab", ["repo", "delete", repo, "--yes"], stderr_to_stdout: true)
  def forge_delete("gitea", repo), do: System.cmd("tea", ["repo", "delete", repo, "--confirm"], stderr_to_stdout: true)

  defp provision(nil, _dir, _remote, _opts),
    do: {:skip, "no forge CLI (gh/glab/tea) on PATH — create the remote yourself + use mirror/3"}

  defp provision("github", dir, remote, opts) do
    name = opts[:repo] || "wb-#{Path.basename(dir)}"
    vis = opts[:visibility] || "private"

    case System.cmd("gh", ["repo", "create", name, "--source", ".", "--#{vis}", "--push", "--remote", remote], cd: dir, stderr_to_stdout: true) do
      {_, 0} -> {:ok, remote_url(dir, remote)}
      {out, _} -> {:error, out}
    end
  end

  defp provision(forge, dir, _remote, opts) when forge in ~w(gitlab gitea) do
    cli = @forge_cli[forge]
    name = opts[:repo] || "wb-#{Path.basename(dir)}"

    if has?(cli) do
      System.cmd(cli, ["repo", "create", name], cd: dir, stderr_to_stdout: true)
      forge_push(Path.basename(dir), Keyword.put(opts, :forge, forge))
    else
      {:skip, "#{cli} not installed for #{forge}"}
    end
  end

  # Snapshot the working tree before mirroring, so the rail pushes actual content.
  # `git add -A` is SAFE because the auto-`.gitignore` (Workbooks.Private) excludes
  # session/personal data — a bulk add can't sweep in the signing key or telemetry.
  # Hooks disabled so the global bd hook doesn't touch a non-beads tenant repo.
  defp ensure_commit(dir, %{} = id) do
    git(dir, ["add", "-A"])
    git(dir, ["-c", "core.hooksPath=/dev/null", "commit", "-q", "--allow-empty", "-m", "mirror snapshot"], env: commit_env(id))
  end

  defp ensure_commit(dir, tenant), do: ensure_commit(dir, identity(tenant))

  defp has_remote?(dir, remote), do: match?({_, 0}, git(dir, ["remote", "get-url", remote]))
  defp remote_url(dir, remote) do
    case git(dir, ["remote", "get-url", remote]), do: ({out, 0} -> String.trim(out); _ -> nil)
  end

  defp has?(bin), do: match?({_, 0}, System.cmd("sh", ["-c", "command -v #{bin}"], stderr_to_stdout: true))

  @doc """
  Publish (federate) the tenant's repo over Radicle. Ensures the rad profile +
  the repo (with at least one commit), then `rad init`s it public if not already
  a Radicle repo. Returns its Radicle ID (`rad:...`). Idempotent — re-publishing
  returns the existing RID. NOTE: this registers + makes the repo *announceable*;
  actually serving it to peers needs a running `rad node` + network/seed (see
  `clone/2`).
  """
  def publish(tenant) do
    ensure_rad_profile()
    dir = ensure_repo(tenant)
    git(dir, ["commit", "-q", "--allow-empty", "-m", "init federation"], env: commit_env(identity(tenant)))

    case rid(tenant) do
      nil ->
        {branch, _} = git(dir, ["symbolic-ref", "--short", "HEAD"])

        rad(dir, [
          "init",
          "--name", to_string(tenant),
          "--description", "Workbooks tenant repo",
          "--default-branch", String.trim(branch),
          "--public", "--no-confirm", "--no-seed"
        ])

        rid(tenant)

      existing ->
        existing
    end
  end

  @doc "The tenant repo's Radicle ID (`rad:...`), or nil if not yet published."
  def rid(tenant) do
    case rad(repo_path(tenant), ["inspect", "--rid"]) do
      {out, 0} -> String.trim(out) |> empty_to_nil()
      _ -> nil
    end
  end

  @doc "The repo's delegate DIDs (the identities allowed to sign identity changes)."
  def delegates(tenant) do
    case rad(repo_path(tenant), ["inspect", "--delegates"]) do
      {out, 0} -> out |> String.split("\n", trim: true)
      _ -> []
    end
  end

  @doc """
  Add an org member (by their Radicle DID) as a repo delegate — the org's
  members → the repo's delegates mapping (GIT.org phase 3). Proposes the identity
  revision; auto-accepted while the node DID is the sole delegate.
  """
  def add_delegate(tenant, did) do
    rad(repo_path(tenant), ["id", "update", "--delegate", did, "--no-confirm", "--title", "add delegate", "--description", did])
  end

  @doc """
  Clone a Workbook repo by its Radicle ID into `dest`. The wiring is complete; a
  fetch resolves a RID over the P2P network, so it needs a peer — a running
  `rad node` whose routing reaches a seed serving that RID. With a lone node and
  no peers there is nothing to fetch from. That is the nature of federation
  (≥2 nodes), a deployment topology fact — not missing code. Local publish + RID
  assignment work fully offline (see `publish/3`); cross-machine fetch needs the
  seed peer to exist.
  """
  def clone(rid, dest) do
    ensure_rad_profile()
    rad(".", ["clone", rid, dest])
  end

  defp rad(".", args), do: System.cmd("rad", args, env: rad_env(), stderr_to_stdout: true)
  defp rad(dir, args), do: System.cmd("rad", args, cd: dir, env: rad_env(), stderr_to_stdout: true)

  # rad needs a passphrase to unlock its key; env disables the interactive prompt.
  defp rad_env, do: [{"RAD_PASSPHRASE", System.get_env("RAD_PASSPHRASE", "workbooks")}]

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(s), do: s
end
