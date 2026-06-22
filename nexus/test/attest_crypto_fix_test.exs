defmodule Nexus.AttestCryptoFixTest do
  @moduledoc """
  RED tests for wb-talp — the canonical preimage MUST be injective (no two distinct
  field maps may share signing bytes), and the verify path MUST stay total (no crash)
  on attacker-supplied DIDs.

  These fail against current code:
    * `preimage/1` joins `k=v` with `\\n` and never escapes `\\n`/`=`, so distinct maps
      collide -> a signature is liftable onto a forged map that gains an unauthorized field.
    * `Attest.verify` leaks a KeyError from `Keyring.public_from_did` on a junk-char DID.
  """
  use ExUnit.Case, async: true

  alias Nexus.Attest
  alias Nexus.Keyring

  describe "preimage/1 injectivity (the canonical encoder)" do
    test "distinct field maps MUST NOT produce identical preimage bytes (non-injective today)" do
      # Today both canonicalize to "a=1\nm=x\nz=BIG" — the core defect.
      smuggled = %{"a" => "1", "m" => "x\nz=BIG"}
      forged = %{"a" => "1", "m" => "x", "z" => "BIG"}

      refute Attest.preimage(smuggled) == Attest.preimage(forged),
             "preimage/1 is non-injective: a value containing \\n=  collides onto a 2nd field"
    end

    test "a '=' inside a value MUST NOT collide with a different key/value split" do
      a = %{"k" => "v=w"}
      b = %{"k" => "v", "w" => ""}
      refute Attest.preimage(a) == Attest.preimage(b)
    end

    test "preimage is still deterministic / key-order independent for genuine maps" do
      assert Attest.preimage(%{"b" => "2", "a" => "1"}) ==
               Attest.preimage(%{"a" => "1", "b" => "2"})
    end
  end

  describe "signature-lift attack is blocked" do
    test "a signature over a smuggled value MUST NOT verify for the forged 2-field map" do
      kp = Keyring.generate()
      # Author legitimately signs ONE field `m` whose value happens to contain "\nz=BIG".
      att = Attest.sign(kp, %{"a" => "1", "m" => "x\nz=BIG"})

      forged = %{att | fields: %{"a" => "1", "m" => "x", "z" => "BIG"}}

      refute Attest.verify(forged),
             "signature lift: forged map gained an unauthorized z=BIG field yet verified"
    end

    test "a genuine field value containing \\n and = still round-trips and verifies" do
      kp = Keyring.generate()
      fields = %{"run" => "r1", "note" => "tokens=5\nfoo=bar"}
      att = Attest.sign(kp, fields)

      assert Attest.verify(att, att.did)
      assert att.fields == fields
    end
  end

  describe "verify/2 stays total on malformed input (wb-qbq8 regression through Attest)" do
    test "a DID with a non-base58 char returns false, never crashes" do
      att = %{did: "did:key:z0OIl", sig: "00", fields: %{}}
      assert Attest.verify(att) == false
    end
  end
end
