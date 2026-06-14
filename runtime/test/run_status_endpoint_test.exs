defmodule Workbooks.RunStatusEndpointTest do
  @moduledoc """
  Pins the GET /api/run/:id contract the desktop polls. A live run serves a status
  map; a gone/never-existed run (no live session AND no persisted transcript for
  the caller) serves 200 with {"error":"no such run"} — NOT a 404, not a crash, and
  notably WITHOUT a `status` field (a poller must treat the error shape, not assume
  `status`). Deterministic (Plug.Test; no agent run / LLM).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  defp get(id, tenant) do
    conn(:get, "/api/run/#{id}")
    |> put_req_header("x-tenant", tenant)
    |> Workbooks.Web.call(Workbooks.Web.init([]))
  end

  test "an unknown run id → 200 with the no-such-run error shape (no status field)" do
    conn = get("run-does-not-exist-#{System.unique_integer([:positive])}", "local")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "no such run"
    refute Map.has_key?(body, "status")
  end
end
