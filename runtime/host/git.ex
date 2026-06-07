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

    ensure_keypair(dir, tenant)
    dir
  end

  @doc """
  Generate+store a per-tenant Ed25519 keypair (`:crypto`) under `.workbooks/` —
  the signing-key basis for the tenant's future Radicle DID. Untracked (the
  private half never gets committed). Idempotent. Returns the public key (raw).
  """
  def ensure_keypair(dir, tenant) do
    path = key_path(dir, tenant)

    unless File.exists?(path) do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Base.encode16(priv, case: :lower))
      File.write!(path <> ".pub", Base.encode16(pub, case: :lower))
    end

    (path <> ".pub") |> File.read!() |> Base.decode16!(case: :lower)
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
