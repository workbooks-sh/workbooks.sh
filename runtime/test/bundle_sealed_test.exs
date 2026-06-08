defmodule BundleSealedTest do
  @moduledoc "The sound core of 'rzip': sealed bundle entries (AES-256-GCM, key-gated)."
  use ExUnit.Case, async: true

  alias Workbooks.Bundle.Sealed

  test "seal → open round-trips with the right key" do
    key = Sealed.generate_key()
    env = Sealed.seal("secret payload", key, "entry/a")
    assert Sealed.sealed?(env)
    assert {:ok, "secret payload"} = Sealed.open(env, key, "entry/a")
  end

  test "DEAD-MAN: wrong key cannot open it (no key = noise)" do
    env = Sealed.seal("secret", Sealed.generate_key())
    assert {:error, :auth_failed} = Sealed.open(env, Sealed.generate_key())
  end

  test "tampered ciphertext fails the auth tag" do
    key = Sealed.generate_key()
    env = Sealed.seal("secret", key)
    # flip a byte in the ciphertext region (after magic+iv+tag = 7+12+16 = 35)
    <<head::binary-size(35), b, rest::binary>> = env
    tampered = <<head::binary, Bitwise.bxor(b, 1), rest::binary>>
    assert {:error, :auth_failed} = Sealed.open(tampered, key)
  end

  test "aad is bound — relabelling an entry fails (can't move a sealed entry)" do
    key = Sealed.generate_key()
    env = Sealed.seal("secret", key, "entry/a")
    assert {:error, :auth_failed} = Sealed.open(env, key, "entry/b")
  end

  test "non-sealed input is reported, not mis-opened" do
    assert {:error, :not_sealed} = Sealed.open("just plaintext", Sealed.generate_key())
    refute Sealed.sealed?("plaintext")
  end

  describe "entry sealing + key-gated opening" do
    setup do
      parts = %{"manifest.json" => "{}", "workbook.html" => "<public/>", "data/private.json" => "{\"ssn\":1}"}
      keys = %{}
      keyfn = fn path -> {"k-" <> Base.url_encode64(path, padding: false), :crypto.strong_rand_bytes(32)} end
      {:ok, parts: parts, keys: keys, keyfn: keyfn}
    end

    test "only gated paths are sealed; public stay plaintext", %{parts: parts} do
      # capture the minted keys so we can build a provider
      table = :ets.new(:keys, [:set, :public])
      keyfn = fn path -> kid = "k-" <> path; key = :crypto.strong_rand_bytes(32); :ets.insert(table, {kid, key}); {kid, key} end

      {sealed, refs} = Sealed.seal_entries(parts, ["data/private.json"], keyfn)

      assert sealed["workbook.html"] == "<public/>"
      assert Sealed.sealed?(sealed["data/private.json"])
      assert Map.has_key?(refs, "data/private.json")
      refute Map.has_key?(refs, "workbook.html")

      # provider that releases keys (stands in for the runtime post-auth)
      provider = fn kid -> case :ets.lookup(table, kid) do [{^kid, key}] -> {:ok, key}; _ -> {:error, :denied} end end
      assert {:ok, opened} = Sealed.open_entries(sealed, refs, provider)
      assert opened["data/private.json"] == "{\"ssn\":1}"
      assert opened["workbook.html"] == "<public/>"
    end

    test "a DENIED key release surfaces as that entry's error (the gate holds)", %{parts: parts} do
      keyfn = fn path -> {"k-" <> path, :crypto.strong_rand_bytes(32)} end
      {sealed, refs} = Sealed.seal_entries(parts, ["data/private.json"], keyfn)

      deny = fn _kid -> {:error, :auth_required} end
      assert {:error, {"data/private.json", :auth_required}} = Sealed.open_entries(sealed, refs, deny)
    end
  end
end
