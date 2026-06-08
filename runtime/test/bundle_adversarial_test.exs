defmodule BundleAdversarialTest do
  @moduledoc """
  Adversarial pass on the sealed-bundle primitives: every attempt to read gated
  bytes without the legitimate (key + posture) must FAIL CLOSED — error tuples,
  never a crash, never a leak, never a silent wrong-plaintext.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Bundle.{Sealed, KeyWrap}

  defp flip(bin, i) do
    <<h::binary-size(i), b, t::binary>> = bin
    <<h::binary, Bitwise.bxor(b, 1), t::binary>>
  end

  describe "Sealed — malformed input fails closed (no crash)" do
    test "magic only / truncated envelope → :malformed, not a crash" do
      key = Sealed.generate_key()
      assert {:error, :malformed} = Sealed.open("wbseal1", key)
      assert {:error, :malformed} = Sealed.open("wbseal1" <> :binary.copy(<<0>>, 10), key)
      assert {:error, :malformed} = Sealed.open("wbseal1" <> :binary.copy(<<0>>, 27), key)
    end

    test "stripped magic (raw iv<>tag<>ct) is not mis-opened" do
      key = Sealed.generate_key()
      "wbseal1" <> rest = Sealed.seal("x", key)
      assert {:error, :not_sealed} = Sealed.open(rest, key)
    end

    test "flipping any of iv / tag / ciphertext → :auth_failed" do
      key = Sealed.generate_key()
      env = Sealed.seal("the secret", key, "p")
      # magic(7) iv(12) tag(16) ct...
      assert {:error, :auth_failed} = Sealed.open(flip(env, 8), key, "p")   # iv
      assert {:error, :auth_failed} = Sealed.open(flip(env, 20), key, "p")  # tag
      assert {:error, :auth_failed} = Sealed.open(flip(env, 36), key, "p")  # ct
    end

    test "empty plaintext round-trips (no off-by-one / empty leak)" do
      key = Sealed.generate_key()
      assert {:ok, ""} = Sealed.open(Sealed.seal("", key, "p"), key, "p")
    end
  end

  describe "Sealed — a released key cannot open a DIFFERENT entry (cross-wiring)" do
    test "key for entry A fails on entry B (aad binds key to its path)" do
      ka = Sealed.generate_key()
      kb = Sealed.generate_key()
      sealed = %{
        "a" => Sealed.seal("AAA", ka, "a"),
        "b" => Sealed.seal("BBB", kb, "b")
      }
      refs = %{"a" => %{"key_id" => "a"}, "b" => %{"key_id" => "b"}}

      # broker mistakenly (or maliciously) returns key A for BOTH entries
      provider = fn _id -> {:ok, ka} end
      assert {:error, {"b", :auth_failed}} = Sealed.open_entries(sealed, refs, provider)
    end

    test "a provider that returns a valid-but-wrong-sized key fails, not crashes" do
      sealed = %{"a" => Sealed.seal("AAA", Sealed.generate_key(), "a")}
      refs = %{"a" => %{"key_id" => "a"}}
      # 16-byte key (wrong size) → open reports :not_sealed via the size guard, still closed
      provider = fn _ -> {:ok, :binary.copy(<<0>>, 16)} end
      assert {:error, {"a", _}} = Sealed.open_entries(sealed, refs, provider)
    end
  end

  describe "KeyWrap — malformed / hostile input fails closed" do
    setup do
      {pub, priv} = KeyWrap.generate_recipient()
      {:ok, pub: pub, priv: priv}
    end

    test "non-wrapped binary → :not_wrapped", %{pub: pub, priv: priv} do
      assert {:error, :not_wrapped} = KeyWrap.unwrap("garbage", {pub, priv})
    end

    test "truncated wrapped blob → :malformed (no crash)", %{pub: pub, priv: priv} do
      assert {:error, :malformed} = KeyWrap.unwrap("wbkw1" <> :binary.copy(<<0>>, 10), {pub, priv})
    end

    test "garbage ephemeral point → :unwrap_failed (crypto raise is caught)", %{pub: pub, priv: priv} do
      # well-formed length, random bytes for eph_pub/iv/tag/ct
      blob = "wbkw1" <> :crypto.strong_rand_bytes(32 + 12 + 16 + 32)
      assert {:error, :unwrap_failed} = KeyWrap.unwrap(blob, {pub, priv})
    end

    test "tampering any region → :unwrap_failed", %{pub: pub, priv: priv} do
      w = KeyWrap.wrap(Sealed.generate_key(), pub, "k")
      assert {:error, :unwrap_failed} = KeyWrap.unwrap(flip(w, 6), {pub, priv}, "k")    # eph_pub
      assert {:error, :unwrap_failed} = KeyWrap.unwrap(flip(w, 40), {pub, priv}, "k")   # iv
      assert {:error, :unwrap_failed} = KeyWrap.unwrap(flip(w, 60), {pub, priv}, "k")   # ct/tag
    end
  end

  describe "end-to-end: no path yields plaintext without (right key + allowed release)" do
    test "denied release → entry stays sealed; later allow → opens (same bytes)" do
      {pub, priv} = KeyWrap.generate_recipient()
      ck = Sealed.generate_key()
      sealed = %{"d" => Sealed.seal("TOPSECRET", ck, "d")}
      refs = %{"d" => %{"key_id" => "d"}}
      wrapped = KeyWrap.wrap(ck, pub, "d")

      deny = KeyWrap.provider(fn _ -> {:error, :auth_required} end, {pub, priv})
      assert {:error, {"d", :auth_required}} = Sealed.open_entries(sealed, refs, deny)

      allow = KeyWrap.provider(fn "d" -> {:ok, wrapped} end, {pub, priv})
      assert {:ok, %{"d" => "TOPSECRET"}} = Sealed.open_entries(sealed, refs, allow)
    end
  end
end
