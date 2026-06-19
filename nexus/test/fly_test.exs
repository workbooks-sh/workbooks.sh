defmodule Nexus.FlyTest do
  use ExUnit.Case, async: true

  test "build_request pins the API host and NEVER carries the token (token added only in :httpc)" do
    {m, url, headers, body} = Nexus.Fly.build_request(:post, ["apps"], %{"app_name" => "x", "org_slug" => "personal"})
    assert m == :post
    assert url == "https://api.machines.dev/v1/apps"
    assert {"content-type", "application/json"} in headers
    assert Jason.decode!(body)["app_name"] == "x"
    # The pure request shape must not leak an authorization header / token.
    refute Enum.any?(headers, fn {k, _} -> String.downcase(k) == "authorization" end)
  end

  test "the API host is a fixed constant (not redirectable by input)" do
    assert Nexus.Fly.api_host() == "https://api.machines.dev/v1"
  end

  test "TLS is verify_peer with a pinned SNI + real CA store (no MITM token theft)" do
    ssl = Nexus.Fly.http_options()[:ssl]
    assert ssl[:verify] == :verify_peer
    assert ssl[:server_name_indication] == ~c"api.machines.dev"
    assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
  end
end
