defmodule Nexus.AuthorshipTest do
  use ExUnit.Case, async: true
  alias Nexus.{Authorship, Keyring}

  test "registration message is canonical + uid-normalized" do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)
    assert Authorship.registration_message("Shane@X.com", did) ==
             Authorship.registration_message("shane@x.com", did)
  end

  test "a device proves possession of its key and registers" do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)
    sig = Keyring.sign(kp.private, Authorship.registration_message("u@x", did)) |> Base.encode16(case: :lower)

    assert Authorship.verify_registration("u@x", did, sig)
    # uid is part of the signed message → can't be replayed under another account
    refute Authorship.verify_registration("other@x", did, sig)
  end

  test "a signature from a different key fails registration" do
    real = Keyring.generate()
    impostor = Keyring.generate()
    did = Keyring.did(real.public)
    forged = Keyring.sign(impostor.private, Authorship.registration_message("u@x", did)) |> Base.encode16(case: :lower)
    refute Authorship.verify_registration("u@x", did, forged)
  end

  test "verify_registration is total over junk" do
    refute Authorship.verify_registration("u", "did:key:znope", "zz")
    refute Authorship.verify_registration("u", "not-a-did", "00")
  end

  test "verified_author? checks registered, non-revoked device set" do
    did = Keyring.did(Keyring.generate().public)
    other = Keyring.did(Keyring.generate().public)
    keys = [%{did: did, revoked: 0}, %{did: other, revoked: 1}]

    assert Authorship.verified_author?(did, keys)
    refute Authorship.verified_author?(other, keys)        # revoked
    refute Authorship.verified_author?("did:key:zunknown", keys)
    refute Authorship.verified_author?("", keys)
    refute Authorship.verified_author?(nil, keys)
  end

  test "verify_contribution requires a valid sig over the exact edit AND a registered key" do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)
    keys = [%{did: did, revoked: 0}]
    target = "site/lander/index.work"
    h = Authorship.content_hash("the new bytes")

    sig = Keyring.sign(kp.private, Authorship.contribution_message("u@x", did, target, h)) |> Base.encode16(case: :lower)
    assert Authorship.verify_contribution("u@x", did, sig, target, h, keys)

    # signature is bound to the content — a swapped edit fails
    refute Authorship.verify_contribution("u@x", did, sig, target, Authorship.content_hash("tampered"), keys)
    # ...and to the path
    refute Authorship.verify_contribution("u@x", did, sig, "other/path.work", h, keys)
    # ...and the key must be registered
    refute Authorship.verify_contribution("u@x", did, sig, target, h, [])
  end

  test "decide/2 is the one policy ladder, identical for every ingress" do
    assert Authorship.decide(true, :off) == :accept
    assert Authorship.decide(true, :hard) == :accept
    assert Authorship.decide(false, :off) == :accept
    assert Authorship.decide(false, :soft) == :accept_unverified
    assert Authorship.decide(false, :hard) == :reject
  end
end
