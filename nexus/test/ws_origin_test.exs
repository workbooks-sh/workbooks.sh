defmodule Nexus.WsOriginTest do
  @moduledoc "Seam 1.3 / wb-k8wz: /ws upgrade rejects cross-origin handshakes (CSWSH guard)."
  use ExUnit.Case, async: true

  test "same-origin allowed" do
    assert Nexus.Ws.origin_ok?("https://nexus.example.com", "nexus.example.com")
    assert Nexus.Ws.origin_ok?("https://nexus.example.com:443/x", "nexus.example.com")
  end

  test "cross-origin rejected (CSWSH)" do
    refute Nexus.Ws.origin_ok?("https://evil.com", "nexus.example.com")
    refute Nexus.Ws.origin_ok?("http://nexus.example.com.evil.com", "nexus.example.com")
  end

  test "no Origin (non-browser client) allowed" do
    assert Nexus.Ws.origin_ok?(nil, "nexus.example.com")
    assert Nexus.Ws.origin_ok?("", "nexus.example.com")
  end
end
