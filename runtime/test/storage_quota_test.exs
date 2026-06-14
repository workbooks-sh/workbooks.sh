defmodule Workbooks.StorageQuotaTest do
  @moduledoc """
  Per-tenant TOTAL-BYTE quota on the BLOB store (`Workbooks.Storage`). The byte
  ledger (`Workbooks.Storage.Usage`) reuses the StorageBroker sqlite mechanism;
  these tests exercise it directly (fast lane, no network, Local adapter).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Storage
  alias Workbooks.Storage.Usage

  setup do
    # Isolated ledger per test run + a temp Local-storage root so puts succeed
    # without touching network or a shared db.
    usage_db = Path.join(System.tmp_dir!(), "usage_#{System.unique_integer([:positive])}.db")
    :ok = Usage.Server.reset_for_test!(usage_db)

    root = Path.join(System.tmp_dir!(), "blobroot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev_root = System.get_env("WB_DATA")
    prev_backend = System.get_env("WB_STORAGE")
    System.put_env("WB_DATA", root)
    System.put_env("WB_STORAGE", "local")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(usage_db)
      if prev_root, do: System.put_env("WB_DATA", prev_root), else: System.delete_env("WB_DATA")
      if prev_backend, do: System.put_env("WB_STORAGE", prev_backend), else: System.delete_env("WB_STORAGE")
    end)

    # Small cap for the facade tests via env.
    {:ok, cap: 1000}
  end

  test "put under the cap succeeds and accounts bytes" do
    assert :ok = Usage.reserve("t1", "k", 500, quota_bytes: 1000)
    assert Usage.total("t1") == 500
  end

  test "put OVER the cap is rejected with :quota_exceeded (never written)" do
    assert :ok = Usage.reserve("t1", "k1", 800, quota_bytes: 1000)
    assert {:error, :quota_exceeded} = Usage.reserve("t1", "k2", 300, quota_bytes: 1000)
    # The rejected key never landed in the ledger.
    assert Usage.total("t1") == 800
  end

  test "delete frees space" do
    assert :ok = Usage.reserve("t1", "k", 900, quota_bytes: 1000)
    assert {:error, :quota_exceeded} = Usage.reserve("t1", "k2", 200, quota_bytes: 1000)
    assert :ok = Usage.forget("t1", "k")
    assert Usage.total("t1") == 0
    # Now there's room.
    assert :ok = Usage.reserve("t1", "k2", 200, quota_bytes: 1000)
  end

  test "OVERWRITE adjusts by the delta, not the full new size" do
    assert :ok = Usage.reserve("t1", "k", 600, quota_bytes: 1000)
    # Overwriting the SAME key with 700 means delta +100 -> total 700 (would be 1300
    # and rejected if it double-counted).
    assert :ok = Usage.reserve("t1", "k", 700, quota_bytes: 1000)
    assert Usage.total("t1") == 700

    # And a shrink lowers the total.
    assert :ok = Usage.reserve("t1", "k", 100, quota_bytes: 1000)
    assert Usage.total("t1") == 100
  end

  test "one tenant's usage never affects another's counter" do
    assert :ok = Usage.reserve("alice", "k", 900, quota_bytes: 1000)
    # Bob has his own budget — alice's 900 does not eat into it.
    assert :ok = Usage.reserve("bob", "k", 900, quota_bytes: 1000)
    assert Usage.total("alice") == 900
    assert Usage.total("bob") == 900
    # Alice is near her own cap, independent of bob.
    assert {:error, :quota_exceeded} = Usage.reserve("alice", "k2", 200, quota_bytes: 1000)
    # Bob unaffected.
    assert :ok = Usage.reserve("bob", "k", 100, quota_bytes: 1000)
  end

  test "concurrent puts do NOT race past the cap" do
    # 20 keys of 100 bytes each = 2000 total demanded, cap 1000 -> at most 10 succeed.
    parent = self()

    for i <- 1..20 do
      spawn(fn ->
        res = Usage.reserve("race", "k#{i}", 100, quota_bytes: 1000)
        send(parent, {:done, res})
      end)
    end

    results = for _ <- 1..20, do: receive(do: ({:done, r} -> r))
    oks = Enum.count(results, &(&1 == :ok))

    # Serialized check-then-write means the accepted total never exceeds the cap.
    assert Usage.total("race") <= 1000
    assert Usage.total("race") == oks * 100
    assert oks == 10
  end

  # ── ADVERSARIAL REGRESSIONS (fail against pre-fix logic) ──────────────────────

  test "BLOCKER-4: a failed OVERWRITE of an existing key leaves the ledger at the PRIOR size, not 0" do
    # Drive the REAL facade put/3 flow. First a clean write of "k" (200 bytes).
    t = "ovw-#{System.unique_integer([:positive])}"
    assert :ok = Storage.put(t, "k", String.duplicate("a", 200))
    assert Storage.usage_bytes(t) == 200

    # Now make a LARGER overwrite of the SAME key fail at the backend: poison the
    # write by turning the key's path into a non-empty directory so File.write fails.
    root = System.get_env("WB_DATA")
    keypath = Path.join([root, t, "blobs", "k"])
    File.rm_rf!(keypath)
    File.mkdir_p!(Path.join(keypath, "child"))

    res = Storage.put(t, "k", String.duplicate("b", 300))
    assert match?({:error, _}, res), "expected the overwrite write to fail, got #{inspect(res)}"

    # Pre-fix: release deleted the row -> usage dropped to 0 (lost the prior 200).
    # Post-fix: release restores the EXACT prior 200.
    assert Storage.usage_bytes(t) == 200
  end

  test "BLOCKER-4: a failed write of a genuinely NEW key drops the row to 0 (no orphan reservation)" do
    t = "new-#{System.unique_integer([:positive])}"
    # Poison the very first write of a brand-new key.
    root = System.get_env("WB_DATA")
    keypath = Path.join([root, t, "blobs", "fresh"])
    File.mkdir_p!(Path.join(keypath, "child"))

    res = Storage.put(t, "fresh", String.duplicate("z", 100))
    assert match?({:error, _}, res)
    # A genuinely new key that failed to write leaves NO charge.
    assert Storage.usage_bytes(t) == 0
  end

  test "BLOCKER-2: presign(:put) over the cap is rejected; under cap reserves the bytes" do
    System.put_env("WB_STORAGE", "r2")

    # Inject a config so no network; tiny cap so the declared length matters.
    cfg = %{endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "b",
            key: "AKIA", secret: "sek", region: "auto"}
    t = "presign-#{System.unique_integer([:positive])}"

    # Over the cap -> rejected, no URL, nothing reserved.
    assert {:error, :quota_exceeded} =
             Storage.presign(t, "big", :put, config: cfg, content_length: 5000, quota_bytes: 1000)
    assert Storage.usage_bytes(t) == 0

    # Under the cap -> reserved; usage reflects the DECLARED length.
    assert {:ok, url} = Storage.presign(t, "ok", :put, config: cfg, content_length: 400, quota_bytes: 1000)
    assert String.contains?(url, "X-Amz-Signature=")
    assert Storage.usage_bytes(t) == 400
  end

  test "BLOCKER-2: presign(:put) WITHOUT content_length is refused (no unmetered URL)" do
    System.put_env("WB_STORAGE", "r2")
    cfg = %{endpoint: "https://acct.r2.cloudflarestorage.com", bucket: "b",
            key: "AKIA", secret: "sek", region: "auto"}
    t = "presign-nolen-#{System.unique_integer([:positive])}"
    assert {:error, :content_length_required} = Storage.presign(t, "k", :put, config: cfg)
    assert Storage.usage_bytes(t) == 0
    # GET (download) is unaffected by the quota and needs no content_length.
    assert {:ok, _} = Storage.presign(t, "k", :get, config: cfg)
  end

  test "BLOCKER-3: a backend-delete FAILURE keeps the ledger row + surfaces the error" do
    # Drive the Local adapter and make File.rm fail with a non-ENOENT error by
    # pointing the key at a DIRECTORY (rm of a non-empty dir -> :eexist/:eisdir),
    # not a regular file. The facade must NOT forget the ledger row.
    t = "del-#{System.unique_integer([:positive])}"
    assert :ok = Storage.put(t, "keep", String.duplicate("z", 100))
    assert Storage.usage_bytes(t) == 100

    # Create a non-empty directory exactly where delete will try to rm a file.
    root = System.get_env("WB_DATA")
    blobdir = Path.join([root, t, "blobs", "stuck"])
    File.mkdir_p!(Path.join(blobdir, "child"))
    File.write!(Path.join([blobdir, "child", "f"]), "x")
    # Also charge the ledger for that key so we can prove it stays charged.
    assert :ok = Usage.reserve(t, "stuck", 100, quota_bytes: 10_000)
    assert Usage.total(t) == 200

    res = Storage.delete(t, "stuck")
    assert match?({:error, _}, res), "expected delete to surface the backend error, got #{inspect(res)}"
    # Fail-CLOSED: the bytes stay charged (row NOT forgotten).
    assert Usage.total(t) == 200
  end

  test "facade put/3 enforces the quota end-to-end and delete frees it" do
    cap = "300"
    prev = System.get_env("WB_STORAGE_QUOTA_BYTES")
    System.put_env("WB_STORAGE_QUOTA_BYTES", cap)
    on_exit(fn -> if prev, do: System.put_env("WB_STORAGE_QUOTA_BYTES", prev), else: System.delete_env("WB_STORAGE_QUOTA_BYTES") end)

    t = "facade-#{System.unique_integer([:positive])}"
    assert :ok = Storage.put(t, "a", String.duplicate("x", 200))
    assert Storage.usage_bytes(t) == 200
    # Over the 300-byte cap -> rejected, and the ledger is unchanged (no partial write).
    assert {:error, :quota_exceeded} = Storage.put(t, "b", String.duplicate("y", 200))
    assert Storage.usage_bytes(t) == 200
    # Delete frees space; the next put fits.
    assert :ok = Storage.delete(t, "a")
    assert Storage.usage_bytes(t) == 0
    assert :ok = Storage.put(t, "b", String.duplicate("y", 200))
    assert Storage.usage_bytes(t) == 200
  end
end
