defmodule Nexus.GitSignTest do
  @moduledoc """
  Tests for wb-i2c8 (git half): SSH commit-signature verification against registered device keys.
  Uses ssh-keygen + git to create REAL signed commits, derives the DID from the key's public half, and
  verifies through Nexus.GitSign — proving a contributor's commits are cryptographically theirs.
  """
  use ExUnit.Case
  alias Nexus.{GitSign, Keyring}

  setup do
    dir = Path.join(System.tmp_dir!(), "wb-gitsign-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    key = Path.join(dir, "id")
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", key, "-N", "", "-q"], stderr_to_stdout: true)

    g = fn args -> System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    {_, 0} = g.(["init", "-q"])
    g.(["config", "gpg.format", "ssh"])
    g.(["config", "user.signingkey", key])
    g.(["config", "commit.gpgsign", "true"])
    g.(["config", "user.email", "dev@example.com"])
    g.(["config", "user.name", "dev"])
    File.write!(Path.join(dir, "a.txt"), "hello")
    g.(["add", "-A"])
    {_, 0} = g.(["commit", "-q", "-m", "signed"])
    {sha, 0} = g.(["rev-parse", "HEAD"])

    pub_line = File.read!(key <> ".pub")
    {:ok, pub} = GitSign.pub_from_ssh_line(pub_line)
    did = Keyring.did(pub)

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, sha: String.trim(sha), did: did, g: g}
  end

  test "ssh pubkey line round-trips a did (wire format matches OpenSSH)", %{did: did} do
    {:ok, line} = GitSign.did_to_ssh_line(did)
    assert String.starts_with?(line, "ssh-ed25519 ")
    {:ok, pub} = GitSign.pub_from_ssh_line(line)
    assert Keyring.did(pub) == did
  end

  test "verify_commit accepts a commit signed by a registered did", %{dir: dir, sha: sha, did: did} do
    assert GitSign.verify_commit(dir, sha, "dev@example.com", [did])
  end

  test "verify_commit rejects an unregistered signer", %{dir: dir, sha: sha} do
    other = Keyring.did(Keyring.generate().public)
    refute GitSign.verify_commit(dir, sha, "dev@example.com", [other])
  end

  test "per-author binding: verifies ONLY under the committer's matching principal (wb-3e2y)", %{dir: dir, sha: sha, did: did} do
    # The commit's committer is dev@example.com. A non-matching principal must NOT verify even though the
    # signing key is valid and present — 'No principal matched' is a rejection, not a pass.
    refute GitSign.verify_commit(dir, sha, "someone-else@example.com", [did])
    assert GitSign.verify_commit(dir, sha, "dev@example.com", [did])
  end

  test "verify_commit with no/malformed dids is false (no raise)", %{dir: dir, sha: sha} do
    refute GitSign.verify_commit(dir, sha, "dev@example.com", [])
    refute GitSign.verify_commit(dir, sha, "dev@example.com", ["did:key:z0OIl"])
  end

  test "an UNSIGNED commit fails verification", %{dir: dir, did: did, g: g} do
    g.(["config", "commit.gpgsign", "false"])
    File.write!(Path.join(dir, "b.txt"), "x")
    g.(["add", "-A"])
    g.(["commit", "-q", "-m", "unsigned"])
    {sha2, 0} = g.(["rev-parse", "HEAD"])
    refute GitSign.verify_commit(dir, String.trim(sha2), "dev@example.com", [did])
  end

  test "verify_push verifies every commit a push introduces", %{dir: dir, sha: sha, did: did} do
    zero = String.duplicate("0", 40)
    # branch creation: whole history of HEAD is signed
    assert GitSign.verify_push(dir, zero, sha, "dev@example.com", [did])
  end
end
