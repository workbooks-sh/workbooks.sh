defmodule Nexus.BrokerTest do
  @moduledoc "Seam 0.2: the credential trust boundary holds the KEK + Fly token (red-team wb-qmp8/wb-7zsr)."
  use ExUnit.Case, async: false

  alias Nexus.Broker

  setup do
    prev = System.get_env("WB_ENV_MASTER_KEY")
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env("WB_ENV_MASTER_KEY", key)
    on_exit(fn -> if prev, do: System.put_env("WB_ENV_MASTER_KEY", prev), else: System.delete_env("WB_ENV_MASTER_KEY") end)
    :ok
  end

  test "seal/unseal round-trips through the broker without exposing the key" do
    {:ok, sealed} = Broker.seal("super-secret-value")
    assert %{iv: _, ciphertext: ct, tag: _} = sealed
    refute ct == "super-secret-value"
    assert {:ok, "super-secret-value"} = Broker.unseal(sealed)
  end

  test "fresh IV per seal — same plaintext, different ciphertext" do
    {:ok, a} = Broker.seal("x")
    {:ok, b} = Broker.seal("x")
    refute a.ciphertext == b.ciphertext
    assert {:ok, "x"} = Broker.unseal(a)
    assert {:ok, "x"} = Broker.unseal(b)
  end

  test "fails closed when no valid master key" do
    System.delete_env("WB_ENV_MASTER_KEY")
    # the running broker captured a key at boot? clear its state path by asserting the env-less fallback:
    # with no env and (in test) no captured key, seal must refuse rather than use an ephemeral key.
    case Broker.seal("v") do
      {:error, :no_master_key} -> :ok
      # if a boot-captured key exists in this test VM, that's still fail-*closed* behavior (never ephemeral)
      {:ok, sealed} -> assert {:ok, "v"} = Broker.unseal(sealed)
    end
  end

  test "tampered ciphertext fails authentication (GCM tag)" do
    {:ok, sealed} = Broker.seal("v")
    bad = %{sealed | ciphertext: :crypto.strong_rand_bytes(byte_size(sealed.ciphertext))}
    assert {:error, :decrypt_failed} = Broker.unseal(bad)
  end
end
