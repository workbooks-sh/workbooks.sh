defmodule Nexus.GitSign do
  @moduledoc """
  SSH commit-signature verification — the git-ingress half of the authorship gate (epic wb-kodp, wb-i2c8).

  A device key (Ed25519, `Nexus.Keyring`) is also an SSH key, so a contributor can SSH-sign their git
  commits (`git -c gpg.format=ssh -c user.signingkey=<key> commit -S`). On push, the nexus verifies each
  pushed commit was signed by one of the contributor's REGISTERED device keys — turning "who authored
  this" from a forgeable commit field into a cryptographic fact. This module is the generic verifier:
  given a repo, a commit (or push range), the signer principal, and the set of allowed `did:key`s, it
  builds an OpenSSH allowed-signers file and uses `git verify-commit` to check the signature.

  THE LINE: this is generic mechanism (verify against a supplied key set); the cloud supplies the device
  registry. The runtime never hard-codes whose keys are trusted.
  """

  alias Nexus.Keyring

  @zero String.duplicate("0", 40)

  @doc "An OpenSSH `ssh-ed25519 <base64>` public-key line built from a 32-byte Ed25519 public key."
  @spec ssh_pubkey_line(binary()) :: String.t()
  def ssh_pubkey_line(pub) when is_binary(pub) and byte_size(pub) == 32 do
    blob = ssh_str("ssh-ed25519") <> ssh_str(pub)
    "ssh-ed25519 " <> Base.encode64(blob)
  end

  @doc "The `ssh-ed25519` line for a `did:key`, or `:error` if the DID is malformed."
  @spec did_to_ssh_line(String.t()) :: {:ok, String.t()} | :error
  def did_to_ssh_line(did) do
    case Keyring.public_from_did(did) do
      {:ok, pub} -> {:ok, ssh_pubkey_line(pub)}
      _ -> :error
    end
  end

  @doc "Recover the 32-byte Ed25519 public key from an `ssh-ed25519 <base64> [comment]` line."
  @spec pub_from_ssh_line(String.t()) :: {:ok, binary()} | :error
  def pub_from_ssh_line("ssh-ed25519 " <> rest) do
    with b64 when is_binary(b64) <- rest |> String.split() |> List.first(),
         {:ok, <<11::32, "ssh-ed25519", 32::32, pub::binary-size(32)>>} <- Base.decode64(b64) do
      {:ok, pub}
    else
      _ -> :error
    end
  end

  def pub_from_ssh_line(_), do: :error

  @doc """
  Is commit `sha` in `repo` signed by one of `dids` (registered device keys), as principal `principal`
  (the committer email/uid)? Writes a temp allowed-signers file and runs `git verify-commit`. False on
  any malformed DID, unsigned commit, or signature from an unlisted key. Never raises.
  """
  @spec verify_commit(Path.t(), String.t(), String.t(), [String.t()]) :: boolean()
  def verify_commit(repo, sha, principal, dids) do
    lines =
      dids
      |> Enum.flat_map(fn d ->
        case did_to_ssh_line(d) do
          {:ok, line} -> [~s(#{principal} namespaces="git" #{line})]
          :error -> []
        end
      end)

    if lines == [] do
      false
    else
      f = Path.join(System.tmp_dir!(), "wb-signers-#{System.unique_integer([:positive])}")

      try do
        File.write!(f, Enum.join(lines, "\n") <> "\n")
        verify_one(repo, sha, f)
      rescue
        _ -> false
      after
        File.rm(f)
      end
    end
  end

  # PER-AUTHOR binding (fix wb-3e2y). `git verify-commit` reports "Good signature for <the key's
  # allowed-signers label>" and exits 0 whenever the signing key is present — it does NOT bind to the
  # committer. So we bind it ourselves: require the reported principal to equal the commit's OWN
  # committer email. Since the allowed-signers file maps owner_uid → key, this means "the committer is
  # signed by a key registered to that very committer" — not merely by some org key.
  defp verify_one(repo, sha, signers_file) do
    committer =
      case System.cmd("git", ["-C", repo, "show", "-s", "--format=%ce", sha], stderr_to_stdout: true) do
        {c, 0} -> String.trim(c)
        _ -> ""
      end

    {out, code} =
      System.cmd("git", ["-C", repo, "-c", "gpg.ssh.allowedSignersFile=#{signers_file}", "verify-commit", sha],
        stderr_to_stdout: true)

    code == 0 and committer != "" and String.contains?(out, ~s(Good "git" signature for #{committer}))
  end

  @doc """
  Verify EVERY commit a push introduces (`old..new`, or all of `new` for a new ref) is signed by one of
  `dids`. An all-zero `old` (branch creation) verifies the whole reachable history of `new`. Empty range
  is vacuously true.
  """
  @spec verify_push(Path.t(), String.t(), String.t(), String.t(), [String.t()]) :: boolean()
  def verify_push(repo, old, new, principal, dids) do
    range = if old in [@zero, "", nil], do: new, else: "#{old}..#{new}"

    case System.cmd("git", ["-C", repo, "rev-list", range], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.all?(&verify_commit(repo, &1, principal, dids))

      _ ->
        false
    end
  end

  @doc "The deploy-maintained allowed-signers file (the cloud rebuilds it from its device-key registry)."
  @spec allowed_signers_path() :: Path.t()
  def allowed_signers_path, do: Path.join(Nexus.Paths.durable_dir(), "allowed_signers")

  @doc "Write the allowed-signers file from `{owner_uid, did}` entries. Returns the path. Malformed dids skipped."
  @spec write_allowed_signers([{String.t(), String.t()}]) :: Path.t()
  def write_allowed_signers(entries) do
    lines =
      entries
      |> Enum.flat_map(fn {principal, did} ->
        case did_to_ssh_line(did) do
          # The PRINCIPAL is the key's owner uid (fix wb-3e2y) so git binds the committer email to that
          # owner's key — a commit attributed to A must be signed by A's key, not just any org key.
          {:ok, line} -> [~s(#{principal} namespaces="git" #{line})]
          :error -> []
        end
      end)

    path = allowed_signers_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  @doc "Like `verify_push/5` but against an EXISTING allowed-signers `file` (the deploy's registry)."
  @spec verify_push_file(Path.t(), String.t(), String.t(), Path.t()) :: boolean()
  def verify_push_file(repo, old, new, file) do
    range = if old in [@zero, "", nil], do: new, else: "#{old}..#{new}"

    case System.cmd("git", ["-C", repo, "rev-list", range], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.all?(&verify_one(repo, &1, file))

      _ ->
        false
    end
  end

  # ── signing side (wb-knqr) — the shared helper the CLI/editor AND agents use ─────────────────────

  @doc """
  Encode a `Nexus.Keyring` keypair as an OpenSSH ed25519 PRIVATE key (PEM). This is what lets git
  SSH-sign commits with a device/agent key (`git -c user.signingkey=<file> commit -S`); the resulting
  signature verifies via `verify_commit/4` against the same key's `did:key`. Unencrypted (`none` cipher).
  """
  @spec openssh_private_key(Nexus.Keyring.keypair()) :: String.t()
  def openssh_private_key(%{public: pub, private: seed}) when byte_size(pub) == 32 and byte_size(seed) == 32 do
    pubblob = ssh_str("ssh-ed25519") <> ssh_str(pub)
    check = :crypto.strong_rand_bytes(4)
    # OpenSSH stores the ed25519 private as seed(32) ++ public(32).
    priv_section = check <> check <> ssh_str("ssh-ed25519") <> ssh_str(pub) <> ssh_str(seed <> pub) <> ssh_str("wb")
    priv_section = priv_section <> pad(byte_size(priv_section))

    body =
      "openssh-key-v1" <>
        <<0>> <>
        ssh_str("none") <> ssh_str("none") <> ssh_str("") <>
        <<1::32>> <> ssh_str(pubblob) <> ssh_str(priv_section)

    "-----BEGIN OPENSSH PRIVATE KEY-----\n" <> wrap64(body) <> "\n-----END OPENSSH PRIVATE KEY-----\n"
  end

  @doc "Write a keypair's OpenSSH private key to a `0600` file under `dir`; returns the path."
  @spec write_signing_key(Nexus.Keyring.keypair(), Path.t()) :: Path.t()
  def write_signing_key(keypair, dir) do
    path = Path.join(dir, "wb-signing-#{System.unique_integer([:positive])}.key")
    File.write!(path, openssh_private_key(keypair))
    _ = File.chmod(path, 0o600)
    path
  end

  @doc "The `git -c …` args to SSH-sign a commit with the key at `keyfile`."
  @spec sign_args(Path.t()) :: [String.t()]
  def sign_args(keyfile),
    do: ["-c", "gpg.format=ssh", "-c", "user.signingkey=#{keyfile}", "-c", "commit.gpgsign=true"]

  defp pad(n) do
    p = rem(8 - rem(n, 8), 8)
    if p == 0, do: <<>>, else: (for i <- 1..p, into: <<>>, do: <<i>>)
  end

  defp wrap64(bin) do
    bin |> Base.encode64() |> String.to_charlist() |> Enum.chunk_every(70) |> Enum.map_join("\n", &to_string/1)
  end

  defp ssh_str(s), do: <<byte_size(s)::32>> <> s
end
