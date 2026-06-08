defmodule Workbooks.Did.X25519 do
  @moduledoc """
  The DID keyAgreement bridge (wb-dsb, the fiddly bit): map the Ed25519 signing
  key behind a `did:key:z6Mk…` to the X25519 key-agreement key that
  `Workbooks.Bundle.KeyWrap` wraps a content key to.

  W3C `did:key` separates VERIFICATION material (Ed25519, signing) from
  KEY-AGREEMENT material (X25519, encryption). The standard derivation
  ([RFC 7748 / the Ed25519→X25519 birational map]) lets us compute the agreement
  key from the signing key with NO extra published key:

    * PUBLIC:  the Edwards `y` coordinate maps to the Montgomery `u` coordinate by
               `u = (1 + y) / (1 - y)  (mod p)`, p = 2^255 - 19. We decode the
               Ed25519 point from its compressed 32-byte form to recover `y`, then
               apply the map. (This is exactly what libsodium's
               `crypto_sign_ed25519_pk_to_curve25519` does.)
    * PRIVATE: the X25519 scalar is `SHA-512(ed25519_seed)[0..32]`, clamped — the
               same scalar Ed25519 itself uses. (libsodium's
               `crypto_sign_ed25519_sk_to_curve25519`.) The runtime only needs this
               when escrowing to ITSELF; a remote recipient derives it client-side
               from their own seed, so the host only ever needs the PUBLIC map.

  Pure Elixir field arithmetic on `:binary` — no NaCl/libsodium NIF (the runtime
  carries only `:crypto` + `:jason`). Used by the key-release endpoint to wrap an
  escrowed content key to a caller's did.

  did:key public is `z<base58btc(0xED01 || ed25519_pub)>`; this module takes the
  raw 32-byte Ed25519 public key (decode the did via `Workbooks.Git`).

  TODO(wb-v3w): NOT YET verified against published libsodium
  `crypto_sign_ed25519_pk_to_curve25519` vectors — the candidate vector in
  test/did_x25519_test.exs did not match and its provenance is unconfirmed (we did
  NOT iterate on field arithmetic in the REPL, per the project guardrail). The
  round-trip test (wrap→unwrap with a seed-derived keypair) DOES pass, proving the
  map composes correctly with `:crypto`'s X25519. The key-release endpoint stays
  ESCROW-ONLY until a libsodium reference confirms the public map; do not wire
  did-wrap into release until then.
  """

  @p 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED
  # mask to clear the top (sign-of-x) bit of the 256-bit little-endian y encoding
  @y_mask 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  @doc """
  Ed25519 PUBLIC key (32 raw bytes) → X25519 PUBLIC key (32 raw bytes), via the
  Montgomery u = (1+y)/(1-y) map. Returns `{:ok, x25519_pub}` or `{:error, reason}`
  (a non-canonical / malformed point fails closed — never raises).
  """
  def ed_pub_to_x25519(<<ed_pub::binary-size(32)>>) do
    with {:ok, y} <- decode_y(ed_pub) do
      # u = (1 + y) * inverse(1 - y)  (mod p)
      one_plus = rem(1 + y, @p)
      one_minus = rem(@p + 1 - y, @p)

      case inv(one_minus) do
        0 -> {:error, :degenerate}
        inv_one_minus -> {:ok, encode_le(rem(one_plus * inv_one_minus, @p))}
      end
    end
  end

  def ed_pub_to_x25519(_), do: {:error, :bad_ed_pub}

  @doc """
  Map a `did:key:z…` (Ed25519) → the recipient's X25519 PUBLIC key (32 bytes).
  Returns `{:ok, x25519_pub}` or `{:error, reason}`. The wrap target for
  `KeyWrap.wrap/3`.
  """
  def recipient_pub("did:key:z" <> _ = did) do
    case ed_pub_of_did(did) do
      {:ok, ed_pub} -> ed_pub_to_x25519(ed_pub)
      err -> err
    end
  end

  def recipient_pub(other), do: {:error, {:unsupported_did, other}}

  @doc """
  Ed25519 SEED (32 bytes) → the X25519 PRIVATE scalar (32 bytes, clamped). The
  runtime uses this ONLY to derive its OWN agreement key for self-escrow; a remote
  recipient runs the same derivation client-side on their own seed.
  """
  def ed_seed_to_x25519_priv(<<seed::binary-size(32)>>) do
    <<scalar::binary-size(32), _::binary>> = :crypto.hash(:sha512, seed)
    clamp(scalar)
  end

  @doc """
  Derive the X25519 PUBLIC key from an Ed25519 seed by the agreement scalar
  (scalar · basepoint). Convenience for self-escrow recipient generation; returns
  `{x25519_pub, x25519_priv}`.
  """
  def x25519_keypair_from_seed(<<seed::binary-size(32)>>) do
    priv = ed_seed_to_x25519_priv(seed)
    {pub, _} = :crypto.generate_key(:ecdh, :x25519, priv)
    {pub, priv}
  end

  # ── did decode ──────────────────────────────────────────────────────────────
  # did:key:z<base58btc(0xED01 || pub)> → the raw 32-byte Ed25519 public key.
  defp ed_pub_of_did("did:key:z" <> b58) do
    case decode58(b58) do
      <<0xED, 0x01, pub::binary-size(32)>> -> {:ok, pub}
      _ -> {:error, :not_ed25519_did}
    end
  rescue
    _ -> {:error, :bad_did}
  end

  # ── Ed25519 point decode: recover y from the compressed 32-byte encoding ──────
  # The encoding is little-endian y with the sign of x in the high bit (which we
  # discard — only y is needed for the u-coordinate map).
  defp decode_y(<<bytes::binary-size(32)>>) do
    y = :binary.decode_unsigned(bytes, :little) |> Bitwise.band(@y_mask)
    if y < @p, do: {:ok, y}, else: {:error, :non_canonical_y}
  end

  # ── field helpers (mod p = 2^255-19) ─────────────────────────────────────────
  defp inv(0), do: 0
  defp inv(a), do: powmod(rem(a + @p, @p), @p - 2, @p)

  defp powmod(_b, 0, _m), do: 1

  defp powmod(b, e, m) do
    half = powmod(b, div(e, 2), m)
    sq = rem(half * half, m)
    if rem(e, 2) == 1, do: rem(sq * b, m), else: sq
  end

  # integer → 256-bit little-endian (the X25519 u-coordinate wire form)
  defp encode_le(n), do: <<n::little-unsigned-256>>

  # X25519 scalar clamping (RFC 7748): clear low 3 bits, clear high bit, set
  # second-highest bit — on the LITTLE-ENDIAN scalar.
  defp clamp(<<lo, mid::binary-size(30), hi>>) do
    <<Bitwise.band(lo, 248), mid::binary, Bitwise.bor(Bitwise.band(hi, 127), 64)>>
  end

  # base58btc decode (Bitcoin alphabet) — the multibase `z` of did:key.
  @b58 ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  defp decode58(str) do
    n = str |> String.to_charlist() |> Enum.reduce(0, fn ch, acc -> acc * 58 + Enum.find_index(@b58, &(&1 == ch)) end)
    zeros = str |> String.to_charlist() |> Enum.take_while(&(&1 == ?1)) |> length()
    :binary.copy(<<0>>, zeros) <> :binary.encode_unsigned(n)
  end
end
