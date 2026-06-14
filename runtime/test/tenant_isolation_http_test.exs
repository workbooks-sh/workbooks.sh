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

  setup do
    # Ensure the dev x-tenant fallback is active (not locked / not multi / not desktop).
    saved = for k <- ~w(WB_PUBLIC_BEARER WB_TENANCY_MODE WB_DESKTOP), do: {k, System.get_env(k)}
    for k <- ~w(WB_PUBLIC_BEARER WB_TENANCY_MODE WB_DESKTOP), do: System.delete_env(k)
    on_exit(fn -> for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k)) end)
    :ok
  end

  defp req(method, path, tenant, body \\ nil) do
    c = conn(method, path, body || "")
    c = if tenant, do: put_req_header(c, "x-tenant", tenant), else: c
    c = if body, do: put_req_header(c, "content-type", "application/json"), else: c
    Workbooks.Web.call(c, Workbooks.Web.init([]))
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
