defmodule BundleShipSealedTest do
  @moduledoc """
  Phase 1 (wb-v3w): seal-on-ship + escrow key-release. A `.wbundle` seals gated
  paths; the content key is escrowed at the runtime (never in the bundle); the
  manifest carries only key_refs; release happens through the escrow store gated by
  Workbooks.Access (the runtime POST /rcp/key/:id path is exercised at the Access +
  Escrow level here, and end-to-end in WebKeyReleaseTest).

  These pin the LEGACY raw-zip egress (`egress: :wbundle`) — the form where the
  page (`workbook.html`) is a PACKED entry and so can itself be sealed. The new
  self-contained `.html` egress makes the page the carrier (unsealable, it must be
  readable to load); its sealing of FILESYSTEM entries is pinned in
  `bundle_egress_migration_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Bundle
  alias Workbooks.Bundle.Escrow

  test "ship with gated paths seals them, escrows keys, and writes key_refs" do
    blob =
      Bundle.ship("wb-ship-1", "<html>public shell</html>", "VFSBYTES",
        egress: :wbundle,
        gated: ["workbook.html"]
      )

    {manifest, sealed_html, _vfs} = Bundle.restore(blob)

    # the gated entry is a sealed envelope, NOT plaintext
    assert Workbooks.Bundle.Sealed.sealed?(sealed_html)
    refute sealed_html == "<html>public shell</html>"

    # manifest carries a key_ref (path → key_id + algo), never the key itself
    refs = manifest["key_refs"]
    assert is_map(refs)
    assert %{"key_id" => key_id, "algo" => "aes-256-gcm"} = refs["workbook.html"]
    refute Map.has_key?(refs["workbook.html"], "key")

    # the content key is escrowed at the runtime, keyed by key_id
    assert {:ok, key} = Escrow.get(key_id)
    assert byte_size(key) == 32
  end

  test "round-trip: release key → Bundle.open unseals to the original bytes" do
    original = "<html>SECRET DASHBOARD $$$</html>"
    blob = Bundle.ship("wb-ship-2", original, "VFS", egress: :wbundle, gated: ["workbook.html"])
    {manifest, _sealed, _vfs} = Bundle.restore(blob)
    key_id = manifest["key_refs"]["workbook.html"]["key_id"]

    # the production provider hits POST /rcp/key/:id; here we model an ALLOWED
    # release straight from the escrow store (post Access.enforce :allow).
    provider = fn ^key_id -> Escrow.get(key_id) end
    assert {:ok, parts} = Bundle.open(blob, provider)
    assert parts["workbook.html"] == original
  end

  test "public entries stay plaintext; only gated paths are sealed" do
    blob = Bundle.ship("wb-ship-3", "<html>shell</html>", "VFSDATA", egress: :wbundle, gated: ["vfs.sqlite"])
    {manifest, html, vfs} = Bundle.restore(blob)

    assert html == "<html>shell</html>"
    assert Workbooks.Bundle.Sealed.sealed?(vfs)
    assert Map.has_key?(manifest["key_refs"], "vfs.sqlite")
    refute Map.has_key?(manifest["key_refs"], "workbook.html")
  end

  test "no gated opt → no key_refs, nothing sealed (backwards compatible)" do
    blob = Bundle.ship("wb-ship-4", "<html/>", "VFS", egress: :wbundle)
    {manifest, html, _vfs} = Bundle.restore(blob)
    refute Map.has_key?(manifest, "key_refs")
    assert html == "<html/>"
  end

  describe "Access-gated key release (the dead-man switch)" do
    test "ALLOW (authed identity) releases the key" do
      identity = %{user_id: "alice", tenant_id: "acme", session_id: nil}
      assert :allow = Workbooks.Access.enforce(:gated_data, :data, identity)
    end

    test "DENY (anonymous / dev) never releases — same shape as unauthorized" do
      assert {:deny, :auth_required} = Workbooks.Access.enforce(:gated_data, :data, nil)
      assert {:deny, :auth_required} =
               Workbooks.Access.enforce(:gated_data, :data, %{user_id: "dev"})
    end
  end
end
