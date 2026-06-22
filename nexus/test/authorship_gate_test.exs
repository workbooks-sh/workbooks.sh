defmodule Nexus.AuthorshipGateTest do
  @moduledoc """
  RED tests for wb-i2c8: the contribution gate that file_save / commit_tree_change must call on the
  cloud commit path. `Authorship.decide/2` + `verify_contribution/6` already exist + are tested, but
  NOTHING calls them on a commit path. The implementer extracts ONE pure chokepoint:

      Nexus.Authorship.gate_contribution(req :: map, target :: binary, bytes :: iodata) ::
        {:reject, reason} | {:accept, author_did :: binary} | {:accept_unverified, ""}

  Behavior (reads policy from `Nexus.Config.authorship_policy/0`):
    * computes content_hash(bytes), verifies the proof in `req` via verify_contribution/6, then
      routes the boolean through decide/2 with the active policy.
    * :hard + unverified         -> {:reject, _}              (caller turns this into 403)
    * verified (any policy)      -> {:accept, did}            (caller records author = did)
    * :soft + unverified         -> {:accept_unverified, ""}  (caller commits, author = "")
    * :off  + unverified         -> {:accept_unverified, ""}  (commit allowed, author = "")

  `req` carries the author proof the cloud surface received:
      %{author: %{uid:, did:, sig:}, device_keys: [%{did:, revoked:}]}
  """
  use ExUnit.Case, async: false
  alias Nexus.{Authorship, Keyring, Config}

  setup do
    prev = Config.authorship_policy()
    on_exit(fn -> Config.put(:authorship_policy, to_string(prev)) end)
    :ok
  end

  defp valid_req(target, bytes) do
    kp = Keyring.generate()
    did = Keyring.did(kp.public)
    uid = "alice@example.com"
    hash = Authorship.content_hash(bytes)
    msg = Authorship.contribution_message(uid, did, target, hash)
    sig = Keyring.sign(kp.private, msg) |> Base.encode16(case: :lower)

    %{
      author: %{uid: uid, did: did, sig: sig},
      device_keys: [%{did: did, revoked: 0}]
    }
    |> then(&{&1, did})
  end

  test ":hard + no/invalid proof -> {:reject, _}" do
    Config.put(:authorship_policy, "hard")
    target = "site/index.work"
    bytes = "hello"

    req = %{author: %{uid: "alice@example.com", did: "did:key:znope", sig: "00"}, device_keys: []}
    assert {:reject, _} = Authorship.gate_contribution(req, target, bytes)
  end

  test ":hard + valid proof -> {:accept, did}" do
    Config.put(:authorship_policy, "hard")
    target = "site/index.work"
    bytes = "hello"
    {req, did} = valid_req(target, bytes)

    assert {:accept, ^did} = Authorship.gate_contribution(req, target, bytes)
  end

  test ":hard + valid proof but bytes TAMPERED -> {:reject, _} (hash binds the content)" do
    Config.put(:authorship_policy, "hard")
    target = "site/index.work"
    {req, _did} = valid_req(target, "the original bytes")
    assert {:reject, _} = Authorship.gate_contribution(req, target, "DIFFERENT bytes")
  end

  test ":soft + unverified -> {:accept_unverified, \"\"} (commit, author empty)" do
    Config.put(:authorship_policy, "soft")
    req = %{author: %{uid: "a@x", did: "did:key:znope", sig: "00"}, device_keys: []}
    assert {:accept_unverified, ""} = Authorship.gate_contribution(req, "f.work", "b")
  end

  test ":off + unverified -> {:accept_unverified, \"\"} (commit allowed)" do
    Config.put(:authorship_policy, "off")
    req = %{author: %{uid: "a@x", did: "did:key:znope", sig: "00"}, device_keys: []}
    assert {:accept_unverified, ""} = Authorship.gate_contribution(req, "f.work", "b")
  end
end
