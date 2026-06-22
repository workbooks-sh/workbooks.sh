defmodule Nexus.Authorship do
  @moduledoc """
  Author identity — one person, many device keys. The surface-agnostic core of slice 2 (epic wb-kodp).

  A person has ONE identity but signs from many surfaces — browser (WebCrypto/IndexedDB), CLI / editor /
  Claude Code (a key in the OS keychain, bound to the `wbk_` PAT), and nexus-side agents (a provisioned
  key). Each surface holds its own **device key**; all are registered under the user, so an edit from any
  surface is provably theirs. This is the Radicle device-key model: device keys under one identity.

  Registration is proof-of-possession, stateless: from an authenticated session/PAT (which fixes the
  `uid`), the client signs a canonical message binding `uid` + its `did`. The server verifies the
  signature against the DID's own public key — proving the client holds the private half — then records
  `uid → did`. No secret is ever handed out, so there's nothing to replay-steal.

  Verified authorship = a contribution's `author` DID is one of that user's registered, non-revoked
  device keys. THE LINE: keys + proofs are generic mechanism; the dashboard reading them is our cloud.
  """

  alias Nexus.Keyring

  @doc "The canonical message a device signs to register its key under `uid`."
  @spec registration_message(String.t(), String.t()) :: String.t()
  def registration_message(uid, did) when is_binary(uid) and is_binary(did),
    do: "wb-author-key\nuid=" <> String.downcase(uid) <> "\ndid=" <> did

  @doc """
  Verify a registration proof: the holder of `did`'s private key signed `registration_message(uid, did)`.
  `sig` is lower-case hex. Returns `true` only if the signature checks out against the DID's public key.
  """
  @spec verify_registration(String.t(), String.t(), String.t()) :: boolean()
  def verify_registration(uid, did, sig) when is_binary(uid) and is_binary(did) and is_binary(sig) do
    with {:ok, pub} <- Keyring.public_from_did(did),
         {:ok, raw} <- Base.decode16(sig, case: :lower) do
      Keyring.verify(pub, registration_message(uid, did), raw)
    else
      _ -> false
    end
  end

  def verify_registration(_, _, _), do: false

  @doc """
  Is `author_did` a verified author for this user — i.e. one of their registered, non-revoked device
  keys? `device_keys` is a list of maps with `:did` and (optional) `:revoked` truthiness.
  """
  @spec verified_author?(String.t() | nil, [map()]) :: boolean()
  def verified_author?(author_did, device_keys)
      when is_binary(author_did) and author_did != "" and is_list(device_keys) do
    Enum.any?(device_keys, fn k ->
      to_string(Map.get(k, :did)) == author_did and not truthy(Map.get(k, :revoked))
    end)
  end

  def verified_author?(_, _), do: false

  defp truthy(nil), do: false
  defp truthy(0), do: false
  defp truthy(false), do: false
  defp truthy(""), do: false
  defp truthy(_), do: true
end
