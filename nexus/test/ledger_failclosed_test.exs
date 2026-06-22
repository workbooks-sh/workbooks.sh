defmodule Nexus.LedgerFailClosedTest do
  @moduledoc """
  RED tests for the ledger-lane fail-open fixes (wb-2ctu fail-open core + wb-8hax no pinned anchor).

  These encode the CORRECT post-fix behavior and FAIL against current code, proving the bug:
    * Attest.verify must FAIL CLOSED when no expected_did is given (today it accepts any self-consistent
      attacker keypair — attest.ex:57 `expected_did == nil or expected_did == did`).
    * The verify chain must be TOTAL over hostile input (a malformed did:key must not raise —
      keyring.ex:111 `Map.fetch!` raises on non-base58 chars).
    * A pure signer predicate `Attest.signer_ok?/2` must be extracted and be injective (exact match only).
    * `Ledger.expected_did/1` must resolve the pinned anchor (explicit arg else `Nexus.Config.ledger_did/0`).
    * `Ledger.read_meters/1,2` must default to the resolved anchor and treat unpinned deploys as UNVERIFIED.

  Helpers the implementer must provide (named exactly as the spec proposes):
    * Nexus.Attest.signer_ok?(did, expected_did) :: boolean
    * Nexus.Ledger.expected_did(explicit \\ nil) :: String.t() | nil
    * Nexus.Config.ledger_did/0 :: String.t() | nil
    * Nexus.Keyring.base58_decode(str) :: {:ok, binary} | :error
  """
  use ExUnit.Case
  alias Nexus.{Attest, Ledger, Keyring, Git, Config}

  setup do
    dir = Path.join(System.tmp_dir!(), "wb-ledger-fc-#{System.unique_integer([:positive])}")
    Git.ensure(dir)
    File.write!(Path.join(dir, "a.txt"), "hello")
    {:ok, sha} = Git.commit(dir, "first")
    on_exit(fn ->
      File.rm_rf(dir)
      # leave config in a neutral state for other tests
      Config.put(:ledger_did, nil)
    end)
    {:ok, dir: dir, sha: sha}
  end

  # ── Attest.signer_ok?/2 — the extracted pure predicate (injective, no accept-all branch) ──────────
  describe "Attest.signer_ok?/2" do
    test "exact DID match passes" do
      did = Keyring.did(Keyring.generate().public)
      assert Attest.signer_ok?(did, did) == true
    end

    test "a different DID fails" do
      did = Keyring.did(Keyring.generate().public)
      other = Keyring.did(Keyring.generate().public)
      refute Attest.signer_ok?(did, other)
    end

    test "nil expected_did fails (no accept-all branch)" do
      did = Keyring.did(Keyring.generate().public)
      refute Attest.signer_ok?(did, nil)
    end
  end

  # ── Attest.verify/2 — must FAIL CLOSED and be TOTAL ───────────────────────────────────────────────
  describe "Attest.verify/2 fail-closed" do
    test "with NO expected_did, an attacker-keypair attestation verifies to FALSE" do
      attacker = Keyring.generate()
      att = Attest.sign(attacker, %{run: "r1", tokens_out: 5})
      # current code returns true here (fail-open); post-fix it must be false.
      refute Attest.verify(att)
    end

    test "with the matching DID it stays true" do
      kp = Keyring.generate()
      att = Attest.sign(kp, %{run: "r1", tokens_out: 5})
      assert Attest.verify(att, Keyring.did(kp.public))
    end

    test "with a non-matching DID it is false even though the sig is self-consistent" do
      kp = Keyring.generate()
      other = Keyring.did(Keyring.generate().public)
      att = Attest.sign(kp, %{run: "r1", tokens_out: 5})
      refute Attest.verify(att, other)
    end
  end

  describe "Attest.verify/2 totality over hostile input" do
    test "a malformed did:key returns false and does NOT raise" do
      some_did = Keyring.did(Keyring.generate().public)
      hostile = %{did: "did:key:z!!!bad", sig: "00", fields: %{}}
      assert Attest.verify(hostile, some_did) == false
    end

    test "a did:key with non-base58 chars in the body returns false and does NOT raise" do
      some_did = Keyring.did(Keyring.generate().public)
      # 0, O, I, l are all OUTSIDE the bitcoin base58 alphabet
      hostile = %{did: "did:key:z0OIl0OIl", sig: "deadbeef", fields: %{x: "1"}}
      assert Attest.verify(hostile, some_did) == false
    end
  end

  # ── Ledger.expected_did/1 — the single place the pinned anchor enters the read path ───────────────
  describe "Ledger.expected_did/1" do
    test "resolves the configured ledger_did when no explicit arg is given" do
      anchor = Keyring.did(Keyring.generate().public)
      Config.put(:ledger_did, anchor)
      assert Ledger.expected_did() == anchor
    end

    test "returns nil when no anchor is configured and no explicit arg given" do
      Config.put(:ledger_did, nil)
      assert Ledger.expected_did() == nil
    end

    test "an explicit arg always wins over config" do
      configured = Keyring.did(Keyring.generate().public)
      explicit = Keyring.did(Keyring.generate().public)
      Config.put(:ledger_did, configured)
      assert Ledger.expected_did(explicit) == explicit
    end
  end

  # ── Ledger.read_meters — anchored + fail-closed default ───────────────────────────────────────────
  describe "Ledger.read_meters anchored to the pinned config DID" do
    test "a runtime-key note verifies true when ledger_did is pinned to that DID", %{dir: dir, sha: sha} do
      runtime = Keyring.generate()
      {:ok, _} = Ledger.write_meter(dir, sha, %{run: "r1", tokens_out: 9}, runtime)
      Config.put(:ledger_did, Keyring.did(runtime.public))

      assert [{_commit, _att, true}] = Ledger.read_meters(dir)
    end

    test "an impostor note under the same pinned config verifies false", %{dir: dir, sha: sha} do
      runtime = Keyring.generate()
      impostor = Keyring.generate()
      {:ok, _} = Ledger.write_meter(dir, sha, %{run: "r1", tokens_out: 9}, impostor)
      Config.put(:ledger_did, Keyring.did(runtime.public))

      assert [{_commit, _att, false}] = Ledger.read_meters(dir)
    end
  end

  describe "Ledger.read_meters fail-closed default (unpinned deploy)" do
    test "with NO ledger_did configured and no explicit arg, every record reads verified?=false", %{dir: dir, sha: sha} do
      runtime = Keyring.generate()
      {:ok, _} = Ledger.write_meter(dir, sha, %{run: "r1", tokens_out: 9}, runtime)
      Config.put(:ledger_did, nil)

      # current code threads nil → Attest.verify accept-all → true (fail-open).
      # post-fix: no anchor ⇒ unverified.
      assert [{_commit, _att, false}] = Ledger.read_meters(dir)
    end
  end
end
