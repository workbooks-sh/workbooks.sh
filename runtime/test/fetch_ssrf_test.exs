defmodule Workbooks.FetchSsrfTest do
  @moduledoc """
  Pins the agent fetch tool's SSRF guard (safe_remote_url/1). The fetch tool runs
  for ALL agents (no exec gate) with an agent-supplied URL, so it must refuse
  private/internal/link-local/loopback targets — especially cloud metadata
  (169.254.169.254) and the runtime's own services — and non-http schemes.
  Deterministic: IP-literal hosts + scheme checks need no DNS.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Agent

  defp ok?(url), do: Agent.safe_remote_url_for_test(url) == :ok

  test "cloud metadata + loopback + private + link-local IP literals are blocked" do
    for url <- [
          "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
          "http://127.0.0.1:4000/api/sessions",
          "http://localhost:4000/health",
          "http://10.0.0.5/internal",
          "http://192.168.1.1/admin",
          "http://172.16.0.9/x",
          "http://[::1]:4000/x",
          "http://0.0.0.0/x"
        ] do
      refute ok?(url), "expected blocked: #{url}"
    end
  end

  test "non-http(s) schemes are blocked" do
    refute ok?("file:///etc/passwd")
    refute ok?("ftp://example.com/x")
    refute ok?("gopher://169.254.169.254/")
  end

  test "a public IP literal passes the guard" do
    # IP literal → no DNS, fully deterministic (offline-safe). 93.184.216.x is a
    # public range; the guard must NOT block it.
    assert ok?("http://93.184.216.34/")
    assert ok?("https://93.184.216.34/docs")
  end

  test "a missing host is rejected" do
    refute ok?("http:///nohost")
  end
end
