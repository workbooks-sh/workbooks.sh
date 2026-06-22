defmodule Nexus.AuthorshipCryptoFixTest do
  @moduledoc """
  RED tests for wb-talp (collision-free authorship messages) + wb-qbq8 (total verifiers).

  Fails against current code:
    * `registration_message/2` and `contribution_message/4` hand-roll "\\n"+"=" joins with
      no escaping, so \\n/= can be shifted across uid/did/target/hash boundaries to collide
      a different field-tuple onto one signing message (signature-lift surface).
    * `verify_registration/3` / `verify_contribution/6` advertise returning false but leak a
      KeyError from `Keyring.public_from_did` on a junk-char DID.
  """
  use ExUnit.Case, async: true

  alias Nexus.Authorship

  describe "contribution_message/4 is collision-free (injective over fields)" do
    test "moving '\\nhash=evil' into target MUST NOT equal the (target, hash) it impersonates" do
      shifted = Authorship.contribution_message("u", "did:key:zX", "a\nhash=evil", "")
      genuine = Authorship.contribution_message("u", "did:key:zX", "a", "evil")

      refute shifted == genuine,
             "contribution_message collides: \\nhash= in target shifts the field boundary"
    end

    test "a '=' inside uid MUST NOT collide with a different did boundary" do
      a = Authorship.contribution_message("u\ndid=did:key:zEVIL", "did:key:zX", "t", "h")
      b = Authorship.contribution_message("u", "did:key:zEVIL", "t", "h")
      # downcase is fine; the boundary just must not be forgeable.
      refute a == b
    end
  end

  describe "registration_message/2 stays collision-free and keeps case-fold" do
    test "uid is still downcased (existing contract preserved)" do
      assert Authorship.registration_message("ALICE", "did:key:zX") ==
               Authorship.registration_message("alice", "did:key:zX")
    end

    test "a '\\ndid=' smuggled into uid MUST NOT collide with a different did" do
      smuggled = Authorship.registration_message("u\ndid=did:key:zEVIL", "did:key:zX")
      genuine = Authorship.registration_message("u", "did:key:zEVIL")
      refute smuggled == genuine
    end
  end

  describe "verifiers stay total on a junk-char DID (no KeyError leak)" do
    test "verify_registration returns false, never crashes" do
      assert Authorship.verify_registration("u", "did:key:z0OIl", "00") == false
    end

    test "verify_contribution returns false, never crashes" do
      keys = [%{did: "did:key:z0OIl"}]
      assert Authorship.verify_contribution("u", "did:key:z0OIl", "00", "t", "h", keys) == false
    end
  end
end
