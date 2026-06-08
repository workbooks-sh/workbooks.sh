defmodule Workbooks.Bundle.KeyWrap do
  @moduledoc """
  Wrap a sealed-bundle CONTENT KEY to a recipient identity (wb sealed-bundle, part
  a). Sealed-box style: an ephemeral X25519 keypair does ECDH against the
  recipient's X25519 public key; the shared secret derives a key-encryption-key
  (KEK) that AES-256-GCM-wraps the content key. Anyone holding the recipient's
  PUBLIC key can wrap to them; only the recipient's PRIVATE key can unwrap.

  Why this matters: the runtime/Worker stores only WRAPPED keys (one per
  authorized recipient) — never the plaintext content key. There is no central
  plaintext-key honeypot; a breach of the broker leaks ciphertext + wrapped keys,
  not content. Combined with Workbooks.Bundle.Sealed, a gated entry is unreadable
  unless you (a) hold the recipient private key and (b) the broker releases your
  wrapped key (posture check, wb-9io).

  Identity linkage: a `did:key` is Ed25519 (signing); encryption uses the paired
  X25519 keyAgreement key the DID document advertises (the W3C/`did:key` standard
  separation of verification vs key-agreement material). This module works on raw
  X25519 keys; the DID bridge maps a recipient DID → its agreement public key.

  Wrapped layout:  "wbkw1" <> eph_pub(32) <> iv(12) <> tag(16) <> ciphertext
  """
  @magic "wbkw1"
  @iv_bytes 12
  @tag_bytes 16

  @doc "A fresh X25519 key-agreement keypair → {public, private} (32 bytes each)."
  def generate_recipient, do: :crypto.generate_key(:ecdh, :x25519)

  @doc """
  Wrap `content_key` (32 bytes) to `recipient_pub` (an X25519 public key). `info`
  is bound into the KEK derivation + the GCM AAD (e.g. the key_id), so a wrapped
  key can't be repurposed for a different entry. Returns the wrapped binary.
  """
  def wrap(content_key, recipient_pub, info \\ "") do
    {eph_pub, eph_priv} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, recipient_pub, eph_priv, :x25519)
    kek = derive(shared, eph_pub, recipient_pub, info)
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, content_key, info, true)
    @magic <> eph_pub <> iv <> tag <> ct
  end

  @doc """
  Unwrap with the recipient's `{pub, priv}` X25519 keypair + the same `info`.
  Returns `{:ok, content_key}` or `{:error, :unwrap_failed}` (wrong recipient,
  tamper, or mismatched info — all fail the tag, indistinguishably).
  """
  def unwrap(@magic <> rest, {recipient_pub, recipient_priv}, info \\ "") do
    # Fail CLOSED on truncated/garbage input — a bad ephemeral point can make
    # :crypto raise, so the whole derivation is guarded.
    case rest do
      <<eph_pub::binary-size(32), iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>> ->
        try do
          shared = :crypto.compute_key(:ecdh, eph_pub, recipient_priv, :x25519)
          kek = derive(shared, eph_pub, recipient_pub, info)

          case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ct, info, tag, false) do
            :error -> {:error, :unwrap_failed}
            key when is_binary(key) -> {:ok, key}
          end
        rescue
          _ -> {:error, :unwrap_failed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  def unwrap(_not_wrapped, _keypair, _info), do: {:error, :not_wrapped}

  @doc """
  A Workbooks.Bundle.Sealed KeyProvider that unwraps from a store of wrapped keys
  using the recipient's keypair. `store.(key_id) -> {:ok, wrapped} | {:error, _}`
  is the broker (the runtime/Worker that holds wrapped keys + enforces posture).
  Returns a fn suitable for `Sealed.open_entries/3`.
  """
  def provider(store, recipient_keypair) do
    fn key_id ->
      with {:ok, wrapped} <- store.(key_id),
           {:ok, key} <- unwrap(wrapped, recipient_keypair, key_id) do
        {:ok, key}
      else
        {:error, _} = e -> e
        other -> {:error, other}
      end
    end
  end

  # KEK = SHA-256 over a domain tag + the shared secret + both public keys + info.
  # Binding both pubkeys + info defends against key-reuse / unknown-key-share.
  defp derive(shared, eph_pub, recipient_pub, info) do
    :crypto.hash(:sha256, ["wbkw1-kek", shared, eph_pub, recipient_pub, info])
  end
end
