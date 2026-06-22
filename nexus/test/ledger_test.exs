defmodule Nexus.LedgerTest do
  use ExUnit.Case
  alias Nexus.{Ledger, Keyring, Git}

  setup do
    dir = Path.join(System.tmp_dir!(), "wb-ledger-#{System.unique_integer([:positive])}")
    Git.ensure(dir)
    File.write!(Path.join(dir, "a.txt"), "hello")
    {:ok, sha} = Git.commit(dir, "first")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, sha: sha}
  end

  test "encode/decode round-trips an attestation losslessly", _ do
    kp = Keyring.generate()
    att = Nexus.Attest.sign(kp, %{run: "r1", agent: "workhorse", tokens_in: 10, tokens_out: 90})
    decoded = Ledger.decode(Ledger.encode(att))
    assert decoded.did == att.did
    assert decoded.sig == att.sig
    # verifies after the round-trip against its signer (fail-closed: must name the expected DID)
    assert Nexus.Attest.verify(decoded, att.did)
  end

  test "encode/decode survives field keys/values that look like headers or contain delimiters", _ do
    kp = Keyring.generate()
    # @-prefixed keys must NOT be sniffed into the header; values with \n/= must survive.
    att = Nexus.Attest.sign(kp, %{"@did" => "spoof", "note" => "x\ntokens=999", "ok" => "1"})
    decoded = Ledger.decode(Ledger.encode(att))
    assert decoded.fields == att.fields
    assert Nexus.Attest.verify(decoded, att.did)
  end

  test "write_meter then read_meters returns a verified record", %{dir: dir, sha: sha} do
    runtime = Keyring.generate()
    {:ok, _att} = Ledger.write_meter(dir, sha, %{run: "r1", agent: "workhorse", tokens_in: 10, tokens_out: 90}, runtime)

    meters = Ledger.read_meters(dir, Keyring.did(runtime.public))
    assert [{commit, att, true}] = meters
    assert String.starts_with?(commit, String.replace(sha, ~r/[^0-9a-f]/, ""))
    assert att.fields["tokens_out"] == "90"
  end

  test "a note from an unknown key reads as unverified against the expected runtime DID", %{dir: dir, sha: sha} do
    impostor = Keyring.generate()
    runtime = Keyring.generate()
    {:ok, _} = Ledger.write_meter(dir, sha, %{run: "r1", tokens_out: 5}, impostor)

    assert [{_commit, _att, false}] = Ledger.read_meters(dir, Keyring.did(runtime.public))
    # fail-closed (wb-2ctu/wb-8hax): with no pinned anchor, a self-consistent note is still UNVERIFIED
    assert [{_commit, _att, false}] = Ledger.read_meters(dir, nil)
  end

  test "read_meters is empty for a repo with no ledger", %{dir: dir} do
    assert Ledger.read_meters(dir) == []
  end
end
