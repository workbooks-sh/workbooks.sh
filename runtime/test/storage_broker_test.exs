defmodule Workbooks.StorageBrokerTest do
  use ExUnit.Case, async: true
  alias Workbooks.StorageBroker

  setup do
    path = Path.join(System.tmp_dir!(), "kv_#{System.unique_integer([:positive])}.db")
    {:ok, conn} = StorageBroker.open(path)
    on_exit(fn -> File.rm(path) end)
    {:ok, conn: conn, path: path}
  end

  test "put/get round-trip, delete, binary-safe values", %{conn: conn} do
    assert :ok = StorageBroker.put(conn, "t1", "k", "v")
    assert {:ok, "v"} = StorageBroker.get(conn, "t1", "k")
    assert {:error, :not_found} = StorageBroker.get(conn, "t1", "missing")

    # arbitrary bytes (nulls, high bytes) survive as a BLOB
    blob = <<0, 1, 2, 255, 0, 10>>
    assert :ok = StorageBroker.put(conn, "t1", "bin", blob)
    assert {:ok, ^blob} = StorageBroker.get(conn, "t1", "bin")

    assert :ok = StorageBroker.delete(conn, "t1", "k")
    assert {:error, :not_found} = StorageBroker.get(conn, "t1", "k")
  end

  test "TENANT ISOLATION — a tenant cannot read or overwrite another's keys", %{conn: conn} do
    assert :ok = StorageBroker.put(conn, "alice", "secret", "ALICE")
    assert :ok = StorageBroker.put(conn, "bob", "secret", "BOB")

    # same key name, different tenants -> different values; no cross-tenant read
    assert {:ok, "ALICE"} = StorageBroker.get(conn, "alice", "secret")
    assert {:ok, "BOB"} = StorageBroker.get(conn, "bob", "secret")

    # bob writing his key does NOT touch alice's
    assert :ok = StorageBroker.put(conn, "bob", "secret", "BOB2")
    assert {:ok, "ALICE"} = StorageBroker.get(conn, "alice", "secret")

    # keys() is scoped to the tenant — bob never sees alice's namespace
    assert StorageBroker.keys(conn, "bob") == ["secret"]
    refute "alice" in StorageBroker.keys(conn, "bob")
  end

  test "DURABLE — values persist across a close + reopen", %{conn: conn, path: path} do
    assert :ok = StorageBroker.put(conn, "t", "k", "persisted")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn2} = StorageBroker.open(path)
    assert {:ok, "persisted"} = StorageBroker.get(conn2, "t", "k")
    :ok = Exqlite.Sqlite3.close(conn2)
  end

  test "QUOTA — per-value size cap rejects oversized values", %{conn: conn} do
    big = String.duplicate("x", 4096)
    assert {:error, :value_too_large} = StorageBroker.put(conn, "t", "k", big, max_value: 1024)
    # under the cap is fine
    assert :ok = StorageBroker.put(conn, "t", "k", String.duplicate("x", 1024), max_value: 1024)
  end

  test "QUOTA — per-tenant key-count cap (updates to existing keys still allowed)", %{conn: conn} do
    for i <- 1..3, do: assert(:ok = StorageBroker.put(conn, "t", "k#{i}", "v", max_keys: 3))
    # a NEW key past the cap is rejected
    assert {:error, :quota_exceeded} = StorageBroker.put(conn, "t", "k4", "v", max_keys: 3)
    # updating an EXISTING key is fine (not a new key)
    assert :ok = StorageBroker.put(conn, "t", "k1", "v2", max_keys: 3)
    assert {:ok, "v2"} = StorageBroker.get(conn, "t", "k1")
  end

  test "rejects empty key/tenant", %{conn: conn} do
    assert {:error, :invalid_key} = StorageBroker.put(conn, "t", "", "v")
    assert {:error, :invalid_key} = StorageBroker.put(conn, "", "k", "v")
  end

  test "MID-FLIGHT REVOCATION — a revoked tenant is denied immediately, restored on unrevoke", %{conn: conn} do
    t = "revt-#{System.unique_integer([:positive])}"
    assert :ok = StorageBroker.put(conn, t, "k", "v")
    assert {:ok, "v"} = StorageBroker.get(conn, t, "k")

    assert :ok = Workbooks.Revocation.revoke(t)
    assert {:error, :revoked} = StorageBroker.put(conn, t, "k", "v2")
    assert {:error, :revoked} = StorageBroker.get(conn, t, "k")

    # access restored on unrevoke; the original value is intact (revocation gates access, not data)
    assert :ok = Workbooks.Revocation.unrevoke(t)
    assert {:ok, "v"} = StorageBroker.get(conn, t, "k")
  end
end
