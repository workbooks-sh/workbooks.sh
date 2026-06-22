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

        {_, code} =
          System.cmd(
            "git",
            ["-C", repo, "-c", "gpg.ssh.allowedSignersFile=#{f}", "verify-commit", sha],
            stderr_to_stdout: true
          )

        code == 0
      rescue
        _ -> false
      after
        File.rm(f)
      end
    end
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

  @doc "Write the allowed-signers file from a set of `did:key`s. Returns the path. Malformed dids are skipped."
  @spec write_allowed_signers([String.t()], String.t()) :: Path.t()
  def write_allowed_signers(dids, principal \\ "member") do
    lines =
      dids
      |> Enum.flat_map(fn d ->
        case did_to_ssh_line(d) do
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
        |> Enum.all?(fn sha ->
          {_, code} =
            System.cmd("git", ["-C", repo, "-c", "gpg.ssh.allowedSignersFile=#{file}", "verify-commit", sha],
              stderr_to_stdout: true)

          code == 0
        end)

      _ ->
        false
    end
  end

  defp ssh_str(s), do: <<byte_size(s)::32>> <> s
end
