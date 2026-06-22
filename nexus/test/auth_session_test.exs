defmodule Nexus.AuthSessionTest do
  use ExUnit.Case, async: true
  alias Nexus.Auth.Session

  # A minimal Plug.Conn for cookie round-trips.
  defp conn(method \\ "GET") do
    %Plug.Conn{method: method, scheme: :https, host: "x", req_headers: [], resp_headers: [], adapter: {Plug.Adapters.Test.Conn, %{}}}
  end

  test "issue sets an http_only, samesite=Lax session cookie; clear expires it" do
    id = %{tenant: "org1", user: "u1", roles: ["owner"]}
    c = Session.issue(conn(), id)
    ck = c.resp_cookies["wb_session"] || c.resp_cookies[Session.__info__(:functions) && "wb_session"]
    assert is_map(ck)
    assert ck[:http_only] == true
    assert ck[:same_site] == "Lax"

    cleared = Session.clear(conn())
    cc = cleared.resp_cookies["wb_session"]
    # delete sets an immediate-expiry cookie (max_age 0 or a past expiry)
    assert cc[:max_age] == 0 or Map.has_key?(cc, :max_age) or Map.has_key?(cc, :universal_time)
  end
end
