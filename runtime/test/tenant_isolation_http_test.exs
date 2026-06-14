defmodule Workbooks.TenantIsolationHttpTest do
  @moduledoc """
  HTTP-level regression guard for the multi-tenant privacy floor (epic wb-g1yo):
  routes real requests through Workbooks.Web (auth → tenant assign → endpoint) in
  dev mode (x-tenant fallback) and asserts a caller cannot see another tenant's
  data, nor read arbitrary host files. One harness pins the wire behavior of the
  fixes whose logic the per-module tests already cover.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Workbooks.SessionLedger

  # All auth-mode env that must be CLEARED so the dev x-tenant fallback is active
  # (not locked / not multi / not desktop / no leaked JWT secret). Includes
  # WB_AUTH_SECRET + a Guardian config reset so a JWT-mode test that ran earlier in
  # the serial phase can't leave this test in multi/JWT mode (wb-q2qg isolation).
  @auth_env ~w(WB_PUBLIC_BEARER WB_TENANCY_MODE WB_DESKTOP WB_AUTH_SECRET)

  setup do
    saved = for k <- @auth_env, do: {k, System.get_env(k)}
    for k <- @auth_env, do: System.delete_env(k)
    reset_guardian()

    # Own WB_DATA (wb-q2qg): a leaked WB_DATA pointing at a deleted dir would make
    # SessionLedger writes silently fail → this test sees no sessions. Use a fresh
    # temp dir. Also pin the toolkit root to the in-tree default.
    prev_data = System.get_env("WB_DATA")
    prev_tk = System.get_env("WB_TOOLKITS_ROOT")
    data = Path.join(System.tmp_dir!(), "wb-tenant-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)
    System.put_env("WB_DATA", data)
    System.delete_env("WB_TOOLKITS_ROOT")

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      reset_guardian()
      if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
      if prev_tk, do: System.put_env("WB_TOOLKITS_ROOT", prev_tk), else: System.delete_env("WB_TOOLKITS_ROOT")
      File.rm_rf(data)
    end)

    :ok
  end

  defp reset_guardian do
    if function_exported?(Workbooks.Auth.Guardian, :install_config, 0),
      do: Workbooks.Auth.Guardian.install_config()
  end

  defp req(method, path, tenant, body \\ nil) do
    c = conn(method, path, body || "")
    c = if tenant, do: put_req_header(c, "x-tenant", tenant), else: c
    c = if body, do: put_req_header(c, "content-type", "application/json"), else: c
    Workbooks.Web.call(c, Workbooks.Web.init([]))
  end

  test "DESKTOP INVARIANT: the single 'local' tenant sees its own + pre-scoping (nil) data" do
    # The desktop authenticates as a stable tenant "local" (Desktop.tenant/0).
    # Tenant-scoping must NOT hide its data: it sees rows it owns AND legacy rows
    # written before scoping existed (tenant == nil). This guards against anyone
    # later dropping the grandfather rule, which would silently empty the desktop.
    SessionLedger.record("desk-own", "waldo", "mine", "/wd", "local")
    SessionLedger.record("desk-legacy", "waldo", "old", "/wd", nil)

    ids = Jason.decode!(req(:get, "/api/sessions", "local").resp_body)["sessions"] |> Enum.map(& &1["session_id"])
    assert "desk-own" in ids, "desktop must see its own sessions"
    assert "desk-legacy" in ids, "desktop must still see pre-scoping (nil-tenant) sessions"
  end

  test "GET /api/sessions is tenant-scoped at the wire" do
    SessionLedger.record("isol-a", "waldo", "alice work", "/wd", "isol-alice")
    SessionLedger.record("isol-b", "waldo", "bob work", "/wd", "isol-bob")

    resp = req(:get, "/api/sessions", "isol-alice")
    assert resp.status == 200
    ids = Jason.decode!(resp.resp_body)["sessions"] |> Enum.map(& &1["session_id"])
    assert "isol-a" in ids
    refute "isol-b" in ids
  end

  test "GET /api/library/:tenant — caller's own tenant 200, another tenant 403 (IDOR)" do
    assert req(:get, "/api/library/isol-alice", "isol-alice").status == 200
    assert req(:get, "/api/library/isol-bob", "isol-alice").status == 403
  end

  test "write/action :tenant-path endpoints reject cross-tenant (IDOR)" do
    # own tenant allowed (200), another tenant forbidden (403). The mirror one is
    # the worst — it would push the whole repo to a caller-supplied git URL.
    for ep <- ["search/", "mirror/", "radicle/"] do
      own_path = "/api/#{ep}isol-alice" <> if(ep == "radicle/", do: "/publish", else: "")
      other_path = "/api/#{ep}isol-bob" <> if(ep == "radicle/", do: "/publish", else: "")
      assert req(:post, own_path, "isol-alice", "{}").status == 200
      assert req(:post, other_path, "isol-alice", "{}").status == 403
    end
  end

  test "workbook reads are tenant-gated (/api/w/:id, /api/workbooks)" do
    # store directly (bypass deploy's git commit) under alice
    Workbooks.ControlPlane.put_workbook("wb-isol", "* secret\n", "isol-alice")

    assert req(:get, "/api/w/wb-isol/org", "isol-alice").status == 200
    # another tenant: 404, no content leaked
    bob = req(:get, "/api/w/wb-isol/org", "isol-bob")
    assert bob.status == 404
    refute bob.resp_body =~ "secret"

    alice_ids = Jason.decode!(req(:get, "/api/workbooks", "isol-alice").resp_body)
    assert "wb-isol" in alice_ids
    refute "wb-isol" in Jason.decode!(req(:get, "/api/workbooks", "isol-bob").resp_body)
  end

  test "GET /api/oql/query confines to .org — no arbitrary host-file read" do
    File.write!("/tmp/wb-it-leak.txt", "* LEAK :secret:\n")
    File.write!("/tmp/wb-it-leak.org", "* LEAK :secret:\n")
    on_exit(fn -> File.rm("/tmp/wb-it-leak.txt"); File.rm("/tmp/wb-it-leak.org") end)

    # non-.org with org content → blocked (not read) → empty headlines
    txt = req(:get, "/api/oql/query?path=/tmp/wb-it-leak.txt", "isol-alice")
    assert Jason.decode!(txt.resp_body)["headlines"] == []

    # control: identical content as .org IS parsed → proves the gate, not a parse quirk
    org = req(:get, "/api/oql/query?path=/tmp/wb-it-leak.org", "isol-alice")
    assert length(Jason.decode!(org.resp_body)["headlines"]) == 1

    # traversal also blocked
    trav = req(:get, "/api/oql/query?path=../../../../etc/passwd", "isol-alice")
    assert Jason.decode!(trav.resp_body)["headlines"] == []
  end
end
