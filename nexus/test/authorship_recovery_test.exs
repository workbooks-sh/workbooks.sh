defmodule Nexus.AuthorshipRecoveryTest do
  @moduledoc """
  wb-13gz: recovery. A locked-out member (lost all device keys) is recovered by an ADMIN re-attesting a
  NEW device key for them. recover_ok?/4 = admin authorization (Authz :manage) AND proof-of-possession
  of the new key bound to the TARGET uid (Authorship.verify_registration). Rotation needs nothing new —
  it's register-new + terminal-revoke-old, both already shipped.
  """
  use ExUnit.Case, async: true
  alias Nexus.{Authorship, Keyring}

  defp proof(uid) do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)
    sig = Keyring.sign(kp.private, Authorship.registration_message(uid, did)) |> Base.encode16(case: :lower)
    {did, sig}
  end

  test "an admin with a valid proof can recover a key for a target user" do
    {did, sig} = proof("victim@x")
    assert Authorship.recover_ok?("admin", "victim@x", did, sig)
    assert Authorship.recover_ok?("owner", "victim@x", did, sig)
  end

  test "a non-admin cannot recover (no privilege escalation)" do
    {did, sig} = proof("victim@x")
    refute Authorship.recover_ok?("member", "victim@x", did, sig)
    refute Authorship.recover_ok?("viewer", "victim@x", did, sig)
  end

  test "recovery still requires proof-of-possession of the new key, bound to the target uid" do
    {did, sig} = proof("victim@x")
    refute Authorship.recover_ok?("admin", "victim@x", did, "deadbeef")  # bad sig
    refute Authorship.recover_ok?("admin", "someone-else@x", did, sig)   # proof bound to victim, not them
    refute Authorship.recover_ok?("admin", "victim@x", "did:key:z0OIl", sig)  # malformed did, no raise
  end
end
