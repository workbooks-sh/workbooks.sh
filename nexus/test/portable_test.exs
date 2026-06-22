defmodule Nexus.PortableTest do
  @moduledoc """
  wb-744n: cross-nexus portability. A did:key is the same identity on every nexus, and Attest/Keyring
  verify a foreign signature with NO shared state — so a user's contributions aggregate across nexuses:
  keep self-consistent (validly-signed) records, optionally only the user's own keys, deduped by commit
  hash (the same commit pushed to N nexuses is ONE contribution).
  """
  use ExUnit.Case, async: true
  alias Nexus.{Portable, Attest, Keyring}

  defp rec(commit, kp, nexus), do: %{commit: commit, att: Attest.sign(kp, %{"commit" => commit}), nexus: nexus}

  test "aggregate dedups the same commit seen on multiple nexuses" do
    kp = Keyring.generate()
    records = [rec("c1", kp, "A"), rec("c1", kp, "B"), rec("c2", kp, "A")]
    commits = Portable.aggregate(records) |> Enum.map(& &1.commit) |> Enum.sort()
    assert commits == ["c1", "c2"]
  end

  test "aggregate drops records whose signature does not verify (tampered)" do
    kp = Keyring.generate()
    good = rec("c1", kp, "A")
    forged = %{commit: "c2", att: %{good.att | fields: %{"commit" => "c2"}}, nexus: "A"}
    commits = Portable.aggregate([good, forged]) |> Enum.map(& &1.commit)
    assert commits == ["c1"]
  end

  test "aggregate with :dids keeps only the user's own keys (cross-nexus global profile)" do
    me = Keyring.generate()
    other = Keyring.generate()
    records = [rec("c1", me, "A"), rec("c2", me, "B"), rec("c3", other, "A")]
    mine = Portable.aggregate(records, dids: [Keyring.did(me.public)]) |> Enum.map(& &1.commit) |> Enum.sort()
    assert mine == ["c1", "c2"]
  end

  test "a contribution signed on nexus A verifies on nexus B with no shared state" do
    kp = Keyring.generate()
    att = Attest.sign(kp, %{"commit" => "x", "tokens" => "42"})
    # 'nexus B' has only the DID — recovered from the attestation itself — yet verifies it.
    assert Attest.verify(att, att.did)
    assert {:ok, _pub} = Keyring.public_from_did(att.did)
  end
end
