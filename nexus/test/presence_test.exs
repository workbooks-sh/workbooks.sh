defmodule Nexus.PresenceTest do
  @moduledoc "Ephemeral presence: touch/typing/here, TTL expiry, and live snapshots to subscribers."
  use ExUnit.Case, async: false

  setup_all do
    case Registry.start_link(keys: :duplicate, name: Nexus.Presence.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Nexus.Presence.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    # isolate channels per test by a unique name
    {:ok, chan: "c-#{System.unique_integer([:positive])}"}
  end

  test "touch makes a user present; here lists them", %{chan: chan} do
    :ok = Nexus.Presence.touch("t1", chan, "alice")
    assert [%{user: "alice", state: :online}] = Nexus.Presence.here("t1", chan)
  end

  test "typing flips state; clearing returns to online", %{chan: chan} do
    Nexus.Presence.typing("t1", chan, "bob", true)
    assert [%{user: "bob", state: :typing}] = Nexus.Presence.here("t1", chan)
    Nexus.Presence.typing("t1", chan, "bob", false)
    assert [%{user: "bob", state: :online}] = Nexus.Presence.here("t1", chan)
  end

  test "presence is tenant + channel scoped", %{chan: chan} do
    Nexus.Presence.touch("t1", chan, "alice")
    Nexus.Presence.touch("t2", chan, "mallory")
    assert Enum.map(Nexus.Presence.here("t1", chan), & &1.user) == ["alice"]
    assert Enum.map(Nexus.Presence.here("t2", chan), & &1.user) == ["mallory"]
  end

  test "leave drops the user", %{chan: chan} do
    Nexus.Presence.touch("t1", chan, "alice")
    Nexus.Presence.leave("t1", chan, "alice")
    assert Nexus.Presence.here("t1", chan) == []
  end

  test "subscribers get a live snapshot on change", %{chan: chan} do
    :ok = Nexus.Presence.subscribe("t1", chan)
    Nexus.Presence.touch("t1", chan, "alice")
    assert_receive {:presence, [%{user: "alice"}]}, 500
  end
end
