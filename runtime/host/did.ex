defmodule Workbooks.Did do
  @moduledoc """
  did:web — the self-host identity rail (Phase 2e). The same Ed25519 key behind
  the tenant's `did:key` (`Workbooks.Git`), republished as a `did:web` document
  resolvable over plain HTTPS. "Self-host for now": no Radicle, no PLC, no
  registry — a standard DID resolver fetches `https://<host>/.well-known/did.json`
  and gets the engine's verification key.

  did:key and did:web wrap the SAME public key, so a signature made by the ledger
  / artifact signer verifies under EITHER DID — did:web just makes the identity
  resolvable by HTTPS-aware verifiers (and is the bridge target a did:plc/ATproto
  record can reference later).
  """
  alias Workbooks.Git

  @doc """
  The DID document for a tenant served at `host`. `host` is the bare authority
  (e.g. `bn-engine-agents.fly.dev`). The verification method's multibase key is
  lifted straight from the tenant's did:key (same bytes, same `z…` encoding).
  """
  def web_document(host, tenant \\ "dev") do
    multibase = Git.did(tenant) |> String.replace_prefix("did:key:", "")
    id = "did:web:#{host}"
    vm = "#{id}#owner"

    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/ed25519-2020/v1"
      ],
      "id" => id,
      "verificationMethod" => [
        %{
          "id" => vm,
          "type" => "Ed25519VerificationKey2020",
          "controller" => id,
          "publicKeyMultibase" => multibase
        }
      ],
      "authentication" => [vm],
      "assertionMethod" => [vm],
      # Cross-link the equivalent did:key so a verifier holding a did:key
      # signature can confirm it's the same subject (and vice-versa).
      "alsoKnownAs" => [Git.did(tenant)]
    }
  end
end
