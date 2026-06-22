defmodule Nexus.Keyring do
  @moduledoc """
  Ed25519 keys + `did:key` identity — the cryptographic root of the ownership ledger.

  This is the Radicle-compatible identity primitive: an Ed25519 keypair, encoded as a W3C `did:key`
  (multicodec `0xed01` ++ pubkey, base58btc, multibase `z` prefix) — the SAME handle Radicle uses for
  a node/device identity. A `did:key` IS the public key (self-certifying), so a contribution signed by a
  key verifies against its DID anywhere, with no registry and no trust in any nexus.

  Two consumers: **author keys** (a person signs their edits) and the **runtime key** (a nexus
  counter-signs metering). Both are just keypairs here; what differs is who holds the private half.

  THE LINE: this is generic mechanism — any deployer's users/nexus get keys + DIDs with none of our
  values baked in. The analytics that read these signatures are our cloud.
  """

  # multicodec varint for ed25519-pub is <<0xED, 0x01>>; multibase base58btc is the leading "z".
  @multicodec_ed25519 <<0xED, 0x01>>
  @b58_alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @b58_tuple List.to_tuple(@b58_alphabet)
  @b58_index @b58_alphabet |> Enum.with_index() |> Map.new()

  @type keypair :: %{public: binary(), private: binary()}

  @doc "Generate a fresh Ed25519 keypair (`%{public: <<32>>, private: <<32>>}`)."
  @spec generate() :: keypair()
  def generate do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: pub, private: priv}
  end

  @doc "Encode an Ed25519 public key as a `did:key` string."
  @spec did(binary()) :: String.t()
  def did(public) when is_binary(public), do: "did:key:z" <> base58_encode(@multicodec_ed25519 <> public)

  @doc "Recover the Ed25519 public key from a `did:key`. `{:ok, pub}` | `:error`."
  @spec public_from_did(String.t()) :: {:ok, binary()} | :error
  def public_from_did("did:key:z" <> rest) do
    case base58_decode(rest) do
      <<0xED, 0x01, pub::binary-size(32)>> -> {:ok, pub}
      _ -> :error
    end
  end

  def public_from_did(_), do: :error

  @doc "A short, human-glanceable fingerprint of a public key (first 8 hex of its SHA-256)."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(public) when is_binary(public),
    do: :crypto.hash(:sha256, public) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @doc "Sign `message` with an Ed25519 private key. Returns the 64-byte signature."
  @spec sign(binary(), iodata()) :: binary()
  def sign(private, message) when is_binary(private),
    do: :crypto.sign(:eddsa, :none, message, [private, :ed25519])

  @doc "Verify an Ed25519 `signature` over `message` against a public key."
  @spec verify(binary(), iodata(), binary()) :: boolean()
  def verify(public, message, signature) when is_binary(public) and is_binary(signature),
    do: :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519])

  def verify(_, _, _), do: false

  @doc """
  Load a keypair from a hex private-key file at `path`, generating + persisting one if absent.

  This is the durable home for a long-lived key (a nexus runtime key, a CLI author key): the private
  key is stored hex-encoded with `0600` perms; the public half is recomputed from it. Idempotent — a
  restart re-reads the same identity. (A secret-store/`Nexus.Secrets` override is wired at the call
  site; this is the on-disk fallback.)
  """
  @spec load_or_create(Path.t()) :: keypair()
  def load_or_create(path) do
    case File.read(path) do
      {:ok, hex} ->
        priv = hex |> String.trim() |> Base.decode16!(case: :lower)
        from_private(priv)

      _ ->
        kp = generate()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Base.encode16(kp.private, case: :lower))
        _ = File.chmod(path, 0o600)
        kp
    end
  end

  @doc "Reconstruct the full keypair (recompute the public key) from a 32-byte private key."
  @spec from_private(binary()) :: keypair()
  def from_private(priv) when is_binary(priv) do
    {pub, ^priv} = :crypto.generate_key(:eddsa, :ed25519, priv)
    %{public: pub, private: priv}
  end

  # ── base58btc (Bitcoin alphabet) — no deps, deterministic ──────────────────────────────────────
  @doc false
  def base58_encode(bin) when is_binary(bin) do
    zeros = bin |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    int = :binary.decode_unsigned(bin)
    body = if int == 0, do: [], else: enc_int(int, [])
    (List.duplicate(?1, zeros) ++ body) |> List.to_string()
  end

  defp enc_int(0, acc), do: acc
  defp enc_int(n, acc), do: enc_int(div(n, 58), [elem(@b58_tuple, rem(n, 58)) | acc])

  @doc false
  def base58_decode(str) when is_binary(str) do
    chars = String.to_charlist(str)
    zeros = chars |> Enum.take_while(&(&1 == ?1)) |> length()
    int = Enum.reduce(chars, 0, fn c, acc -> acc * 58 + Map.fetch!(@b58_index, c) end)
    body = if int == 0, do: <<>>, else: :binary.encode_unsigned(int)
    :binary.copy(<<0>>, zeros) <> body
  end
end
