defmodule Workbooks.Bundle.Sealed do
  @moduledoc """
  Sealed bundle entries — the SOUND core of the "rzip" idea (wb-* sealed-bundle).

  A `.wbundle` is a zip whose directory already ROUTES by path. We make selected
  entries GATED by sealing them: AES-256-GCM ciphertext whose CONTENT KEY never
  ships in the bundle — it is escrowed at the runtime and released only after the
  access posture check (Workbooks.Access) passes over RCP. Without the key a
  sealed entry is just noise: that is the real "dead-man switch" (a KEY the client
  lacks — NOT obfuscation, a forked format, or a client-side guard, all of which
  are bypassable because the attacker owns the client and the bytes).

  Envelope layout (one self-describing binary per sealed entry):

      "wbseal1" <> iv(12) <> tag(16) <> ciphertext

  The manifest (built by the packer) carries a KEY REFERENCE per sealed path
  (`%{path => %{key_id, issuer}}`) — never the key. A KeyProvider resolves a
  key_id → key; the production provider fetches it from the runtime (authed,
  posture-gated); tests inject a static map.
  """
  @magic "wbseal1"
  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc "A fresh 256-bit content key."
  def generate_key, do: :crypto.strong_rand_bytes(@key_bytes)

  @doc """
  Seal plaintext under `key` (32 bytes). `aad` (default the path/key_id) is bound
  into the GCM tag — a sealed entry can't be silently relabelled/moved.
  Returns the envelope binary.
  """
  def seal(plaintext, key, aad \\ "") when byte_size(key) == @key_bytes do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
    @magic <> iv <> tag <> ct
  end

  @doc """
  Open a sealed envelope with `key` + the same `aad`. Returns `{:ok, plaintext}`
  or `{:error, :auth_failed}` — a wrong key, a tampered ciphertext, or a mismatched
  aad ALL fail the GCM tag (indistinguishable, by design).
  """
  def open(@magic <> rest, key, aad \\ "") when byte_size(key) == @key_bytes do
    # Fail CLOSED on a truncated/malformed envelope — never crash, never leak.
    case rest do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>> ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
          :error -> {:error, :auth_failed}
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
        end

      _ ->
        {:error, :malformed}
    end
  end

  def open(_not_sealed, _key, _aad), do: {:error, :not_sealed}

  @doc "Is this binary a sealed envelope?"
  def sealed?(@magic <> _), do: true
  def sealed?(_), do: false

  @doc """
  Seal the entries named in `gated` (a list of paths). Returns
  `{sealed_parts, key_refs}` where `key_refs` is `%{path => %{"key_id" => id}}` for
  the manifest. `keyfn.(path) -> {key_id, key}` mints/looks up a key per entry
  (one key per entry by default, so revoking one doesn't unlock the rest).
  """
  def seal_entries(parts, gated, keyfn) when is_map(parts) and is_list(gated) do
    Enum.reduce(gated, {parts, %{}}, fn path, {acc, refs} ->
      case Map.fetch(acc, path) do
        {:ok, plaintext} ->
          {key_id, key} = keyfn.(path)
          {Map.put(acc, path, seal(plaintext, key, key_id)), Map.put(refs, path, %{"key_id" => key_id})}

        :error ->
          {acc, refs}
      end
    end)
  end

  @doc """
  Open every sealed entry using a KeyProvider. `provider.(key_id) -> {:ok, key} |
  {:error, reason}` (the runtime-release provider gates on auth/posture). Public
  entries pass through untouched. Returns `{:ok, parts}` or
  `{:error, {path, reason}}` — a denied key release surfaces as that entry's error.
  """
  def open_entries(parts, key_refs, provider) when is_map(parts) and is_map(key_refs) do
    Enum.reduce_while(parts, {:ok, %{}}, fn {path, blob}, {:ok, acc} ->
      case key_refs[path] do
        nil ->
          {:cont, {:ok, Map.put(acc, path, blob)}}

        %{"key_id" => key_id} ->
          with {:ok, key} <- provider.(key_id),
               {:ok, plaintext} <- open(blob, key, key_id) do
            {:cont, {:ok, Map.put(acc, path, plaintext)}}
          else
            {:error, reason} -> {:halt, {:error, {path, reason}}}
          end
      end
    end)
  end
end
