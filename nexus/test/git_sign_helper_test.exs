defmodule Nexus.GitSignHelperTest do
  @moduledoc """
  wb-knqr: the SIGNING side of GitSign — turn any Nexus.Keyring keypair into an OpenSSH private key git
  can SSH-sign commits with. The shared helper the CLI/editor AND agents use. Proven end-to-end: sign a
  real commit with the helper, then verify it with the existing verifier against the keypair's DID.
  """
  use ExUnit.Case
  alias Nexus.{GitSign, Keyring}

  test "openssh_private_key/1 produces a key git accepts; the signed commit verifies against its DID" do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)

    dir = Path.join(System.tmp_dir!(), "wb-sign-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    keyfile = GitSign.write_signing_key(kp, dir)
    assert File.read!(keyfile) =~ "BEGIN OPENSSH PRIVATE KEY"

    g = fn args -> System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    {_, 0} = g.(["init", "-q"])
    g.(["config", "user.email", "dev@x"])
    g.(["config", "user.name", "dev"])
    File.write!(Path.join(dir, "a.txt"), "hello")
    g.(["add", "-A"])
    {_, 0} = g.(GitSign.sign_args(keyfile) ++ ["commit", "-q", "-m", "signed via helper"])
    {sha, 0} = g.(["rev-parse", "HEAD"])

    # the existing verifier accepts it, against the keypair's DID
    assert GitSign.verify_commit(dir, String.trim(sha), "dev@x", [did])
    # ...and rejects a different key
    refute GitSign.verify_commit(dir, String.trim(sha), "dev@x", [Keyring.did(Keyring.generate().public)])
  end

  test "ssh-keygen agrees the derived public key matches (key is well-formed)" do
    kp = Keyring.generate()
    dir = Path.join(System.tmp_dir!(), "wb-sign2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    keyfile = GitSign.write_signing_key(kp, dir)

    {out, 0} = System.cmd("ssh-keygen", ["-y", "-f", keyfile], stderr_to_stdout: true)
    {:ok, pub} = GitSign.pub_from_ssh_line(out)
    assert pub == kp.public
  end
end
