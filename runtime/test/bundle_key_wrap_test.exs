defmodule BundleKeyWrapTest do
  @moduledoc "Part (a): content-key wrapping to a recipient identity — no plaintext-key honeypot."
  use ExUnit.Case, async: true

  alias Workbooks.Bundle.{KeyWrap, Sealed}

  test "wrap → unwrap round-trips for the right recipient" do
    {pub, priv} = KeyWrap.generate_recipient()
    ck = Sealed.generate_key()
    wrapped = KeyWrap.wrap(ck, pub, "key-1")
    assert {:ok, ^ck} = KeyWrap.unwrap(wrapped, {pub, priv}, "key-1")
  end

  test "a DIFFERENT recipient cannot unwrap (no plaintext key leaks)" do
    {pub, _priv} = KeyWrap.generate_recipient()
    {other_pub, other_priv} = KeyWrap.generate_recipient()
    wrapped = KeyWrap.wrap(Sealed.generate_key(), pub, "key-1")
    assert {:error, :unwrap_failed} = KeyWrap.unwrap(wrapped, {other_pub, other_priv}, "key-1")
  end

  test "info is bound — a wrapped key can't be repurposed for another entry" do
    {pub, priv} = KeyWrap.generate_recipient()
    wrapped = KeyWrap.wrap(Sealed.generate_key(), pub, "key-1")
    assert {:error, :unwrap_failed} = KeyWrap.unwrap(wrapped, {pub, priv}, "key-2")
  end

  test "tampered wrapped blob fails" do
    {pub, priv} = KeyWrap.generate_recipient()
    wrapped = KeyWrap.wrap(Sealed.generate_key(), pub, "k")
    <<h::binary-size(50), b, rest::binary>> = wrapped
    assert {:error, :unwrap_failed} = KeyWrap.unwrap(<<h::binary, Bitwise.bxor(b, 1), rest::binary>>, {pub, priv}, "k")
  end

  test "END-TO-END: seal entry, wrap its key to a recipient, broker releases wrapped, recipient opens" do
    {pub, priv} = KeyWrap.generate_recipient()

    # author: seal the gated entry under a fresh content key, wrap the key to the recipient
    ck = Sealed.generate_key()
    key_id = "data/private.json"
    parts = %{"workbook.html" => "<public/>", key_id => "{\"ssn\":1}"}
    sealed = Map.put(parts, key_id, Sealed.seal(parts[key_id], ck, key_id))
    refs = %{key_id => %{"key_id" => key_id}}
    wrapped = KeyWrap.wrap(ck, pub, key_id)

    # broker: holds only WRAPPED keys, releases per posture (here: allow)
    store = fn ^key_id -> {:ok, wrapped} end
    provider = KeyWrap.provider(store, {pub, priv})

    assert {:ok, opened} = Sealed.open_entries(sealed, refs, provider)
    assert opened[key_id] == "{\"ssn\":1}"
    assert opened["workbook.html"] == "<public/>"

    # a broker that DENIES release → entry stays closed
    deny = fn _ -> {:error, :auth_required} end
    assert {:error, {^key_id, :auth_required}} = Sealed.open_entries(sealed, refs, KeyWrap.provider(deny, {pub, priv}))
  end
end
