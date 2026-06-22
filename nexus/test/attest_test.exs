defmodule Nexus.AttestTest do
  use ExUnit.Case, async: true
  alias Nexus.{Attest, Keyring}

  test "preimage is canonical regardless of key order" do
    a = Attest.preimage(%{b: 2, a: 1, c: "three"})
    b = Attest.preimage(%{c: "three", a: 1, b: 2})
    assert a == b
    assert a == "a=1\nb=2\nc=three"
  end

  test "sign produces a self-describing attestation that verifies" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{run: "r1", agent: "workhorse", tokens_in: 10, tokens_out: 90})
    assert att.did == Keyring.did(kp.public)
    # fail-closed (wb-2ctu): verify requires the expected signer; an unanchored verify is false
    assert Attest.verify(att, Keyring.did(kp.public))
    refute Attest.verify(att)
  end

  test "tampering with fields breaks verification" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{run: "r1", tokens_out: 90})
    forged = put_in(att.fields[:tokens_out], 9_000)
    refute Attest.verify(forged)
  end

  test "expected_did pins the signer (runtime counter-signature)" do
    runtime = Keyring.generate()
    impostor = Keyring.generate()
    att = Attest.sign(runtime, %{run: "r1", cost: "0.01"})

    assert Attest.verify(att, Keyring.did(runtime.public))
    refute Attest.verify(att, Keyring.did(impostor.public))
  end

  test "verify is total over malformed input" do
    refute Attest.verify(%{})
    refute Attest.verify(%{did: "x", sig: "zz", fields: %{a: 1}})
    refute Attest.verify(nil)
  end
end
