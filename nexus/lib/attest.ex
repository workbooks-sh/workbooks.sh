defmodule Nexus.Attest do
  @moduledoc """
  Signed attestations — the verifiable unit of the ownership ledger.

  An attestation is a flat map of fields (e.g. a metering record `%{run: ..., agent: ..., model: ...,
  tokens_in: ..., tokens_out: ..., started: ..., ended: ...}`) plus a signature over a **canonical
  preimage** of those fields. The signer's `did` rides along so a verifier needs nothing but the
  attestation itself — it recovers the public key from the DID and checks the signature.

  Two attestations bind a contribution:
    * the **author** signs the edit (proves *who*),
    * the **runtime** counter-signs the metering (proves *what* — tokens/cost can't be inflated,
      because the author never holds the runtime key).

  These serialize into `git notes` (`refs/notes/wb-meter`) keyed by the contribution's commit hash, so
  the signed record is anchored to the content-addressed snapshot. THE LINE: the format is generic; the
  dashboard that aggregates verified attestations is our cloud.
  """

  alias Nexus.Keyring

  @type t :: %{did: String.t(), sig: String.t(), fields: map()}

  @doc """
  The canonical signing preimage for a field map: `"key=value"` lines, keys sorted, `\\n`-joined.

  Deterministic and INJECTIVE (via `Nexus.Canon` field escaping), so a signature over one field set can't
  be lifted onto a different set that smuggles an extra field through an unescaped `\\n`/`=` (fix wb-talp).
  """
  @spec preimage(map()) :: String.t()
  def preimage(fields) when is_map(fields), do: Nexus.Canon.kv(fields)

  @doc "Sign a field map with a keypair, returning a self-describing attestation `%{did, sig, fields}`."
  @spec sign(Keyring.keypair(), map()) :: t()
  def sign(%{public: pub, private: priv}, fields) when is_map(fields) do
    sig = Keyring.sign(priv, preimage(fields))
    %{did: Keyring.did(pub), sig: Base.encode16(sig, case: :lower), fields: fields}
  end

  @doc """
  Verify an attestation against its own embedded DID. `true` only if the signature is valid AND, when
  `expected_did` is given, the signer matches it (so you can demand "this must be the runtime key").
  """
  @spec verify(t(), String.t() | nil) :: boolean()
  def verify(attestation, expected_did \\ nil)

  def verify(%{did: did, sig: sig, fields: fields}, expected_did) do
    with true <- expected_did == nil or expected_did == did,
         {:ok, pub} <- Keyring.public_from_did(did),
         {:ok, raw} <- Base.decode16(sig, case: :lower) do
      Keyring.verify(pub, preimage(fields), raw)
    else
      _ -> false
    end
  end

  def verify(_, _), do: false
end
