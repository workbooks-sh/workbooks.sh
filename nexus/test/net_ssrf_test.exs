defmodule Nexus.Net.SsrfTest do
  use ExUnit.Case, async: true

  alias Nexus.Net.Ssrf

  # wb-y4md — the ONE host-side SSRF guard. The old Dock guard checked the literal hostname string;
  # this resolves and rejects if ANY resolved IP is internal. These pin the deny set + the URL gate.

  describe "ip_internal? deny set (mirrors the NIF wb_ip_allowed)" do
    test "IPv4 internal ranges are denied" do
      for ip <- [
            {127, 0, 0, 1},      # loopback
            {10, 1, 2, 3},       # RFC1918
            {172, 16, 0, 1},     # RFC1918
            {172, 31, 255, 254}, # RFC1918 upper
            {192, 168, 1, 1},    # RFC1918
            {169, 254, 169, 254}, # link-local / cloud metadata
            {100, 64, 0, 1},     # CGNAT 100.64/10
            {0, 0, 0, 0},        # unspecified
            {255, 255, 255, 255}, # broadcast
            {224, 0, 0, 1},      # multicast
            {240, 0, 0, 1},      # reserved
            {192, 0, 2, 5}       # documentation
          ] do
        assert Ssrf.ip_internal?(ip), "expected #{inspect(ip)} internal"
      end
    end

    test "IPv4 public addresses are allowed" do
      for ip <- [{1, 1, 1, 1}, {8, 8, 8, 8}, {93, 184, 216, 34}, {172, 15, 0, 1}, {172, 32, 0, 1}] do
        refute Ssrf.ip_internal?(ip), "expected #{inspect(ip)} public"
      end
    end

    test "IPv6 internal + embedded-IPv4 smuggling are denied" do
      assert Ssrf.ip_internal?({0, 0, 0, 0, 0, 0, 0, 1})            # ::1
      assert Ssrf.ip_internal?({0, 0, 0, 0, 0, 0, 0, 0})            # ::
      assert Ssrf.ip_internal?({0xFE80, 0, 0, 0, 0, 0, 0, 1})       # link-local
      assert Ssrf.ip_internal?({0xFC00, 0, 0, 0, 0, 0, 0, 1})       # ULA
      assert Ssrf.ip_internal?({0xFF02, 0, 0, 0, 0, 0, 0, 1})       # multicast
      # ::ffff:127.0.0.1 (IPv4-mapped) and ::ffff:169.254.169.254
      assert Ssrf.ip_internal?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      assert Ssrf.ip_internal?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      # NAT64 64:ff9b::127.0.0.1
      assert Ssrf.ip_internal?({0x0064, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
    end

    test "public IPv6 is allowed" do
      refute Ssrf.ip_internal?({0x2606, 0x4700, 0, 0, 0, 0, 0, 1})  # cloudflare
    end
  end

  describe "allowed?/1 URL gate" do
    test "non-http(s) schemes and empty host are denied" do
      refute Ssrf.allowed?("ftp://example.com/x")
      refute Ssrf.allowed?("file:///etc/passwd")
      refute Ssrf.allowed?("http://")
      refute Ssrf.allowed?(nil)
    end

    test "literal internal IPs are denied (resolve-to-self)" do
      refute Ssrf.allowed?("http://127.0.0.1/")
      refute Ssrf.allowed?("http://169.254.169.254/latest/meta-data/")
      refute Ssrf.allowed?("http://10.0.0.5:4000/")
      refute Ssrf.allowed?("http://100.64.0.1/")
      refute Ssrf.allowed?("http://[::1]/")
    end

    test "literal public IPs are allowed" do
      assert Ssrf.allowed?("https://1.1.1.1/")
      assert Ssrf.allowed?("http://8.8.8.8/")
    end
  end
end
