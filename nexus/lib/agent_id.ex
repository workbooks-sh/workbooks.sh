defmodule Nexus.AgentId do
  @moduledoc """
  Agent signing identities (epic wb-kodp, wb-kxfa) — agents are first-class principals, not anonymous
  authors. Each agent gets a STABLE Ed25519 keypair DERIVED from the nexus runtime key + its name
  (HKDF-style: `sha256(runtime_priv ++ "wb-agent:" ++ name)` as the seed). So:

    * it's reproducible — the nexus re-derives the same key every boot, no storage, no key file;
    * it's nexus-held — only this nexus (holding the runtime key) can sign as its agents;
    * it's self-verifying — `of?/2` re-derives the DID from the name, so agent authorship needs NO
      registry (unlike human device keys): a Run's author DID is genuine iff it re-derives to its agent.

  Distinct from the runtime METERING key (that counter-signs token usage); this attributes AUTHORSHIP to
  the agent. THE LINE: derivation is generic mechanism; which agents exist is the workbook's business.
  """

  alias Nexus.Keyring

  @doc "The stable keypair for agent `name` (derived from the runtime key; reproducible, nexus-held)."
  @spec keypair(String.t()) :: Keyring.keypair()
  def keypair(name) when is_binary(name) do
    seed = :crypto.hash(:sha256, runtime_priv() <> "wb-agent:" <> name)
    Keyring.from_private(seed)
  end

  @doc "Agent `name`'s did:key."
  @spec did(String.t()) :: String.t()
  def did(name), do: name |> keypair() |> Map.fetch!(:public) |> Keyring.did()

  @doc "Does `candidate_did` belong to agent `name`? Self-verifying by re-derivation — no registry."
  @spec of?(String.t() | nil, String.t()) :: boolean()
  def of?(candidate_did, name) when is_binary(candidate_did) and is_binary(name),
    do: candidate_did == did(name)

  def of?(_, _), do: false

  defp runtime_priv, do: Nexus.Ledger.runtime_key().private
end
