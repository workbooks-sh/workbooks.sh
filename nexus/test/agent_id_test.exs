defmodule Nexus.AgentIdTest do
  @moduledoc """
  wb-kxfa: agents are first-class signing principals. Each agent has a STABLE Ed25519 identity derived
  from the nexus runtime key + the agent's name — nexus-held, reproducible, NO storage. An agent's DID
  is self-verifying: the nexus re-derives it from the name, so agent authorship needs no registry.
  """
  use ExUnit.Case, async: false
  alias Nexus.{AgentId, Keyring}

  test "an agent's keypair is stable (same name → same keys)" do
    a = AgentId.keypair("waldo")
    b = AgentId.keypair("waldo")
    assert a.public == b.public and a.private == b.private
    assert byte_size(a.public) == 32 and byte_size(a.private) == 32
  end

  test "distinct agents have distinct identities" do
    refute AgentId.did("waldo") == AgentId.did("autopoet")
  end

  test "the DID is canonical did:key and round-trips to the agent's public key" do
    did = AgentId.did("waldo")
    assert String.starts_with?(did, "did:key:z6Mk")
    assert {:ok, pub} = Keyring.public_from_did(did)
    assert pub == AgentId.keypair("waldo").public
  end

  test "an agent can sign and the derived public verifies it" do
    kp = AgentId.keypair("waldo")
    sig = Keyring.sign(kp.private, "the edit")
    assert Keyring.verify(kp.public, "the edit", sig)
  end

  test "of?/2 self-verifies a DID against an agent name (no registry needed)" do
    assert AgentId.of?(AgentId.did("waldo"), "waldo")
    refute AgentId.of?(AgentId.did("waldo"), "autopoet")
    refute AgentId.of?("did:key:z0OIl", "waldo")
    refute AgentId.of?(nil, "waldo")
  end

  test "an agent identity is distinct from the runtime metering key" do
    refute AgentId.did("waldo") == Nexus.Ledger.runtime_did()
  end
end
