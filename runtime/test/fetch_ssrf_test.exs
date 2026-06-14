defmodule Workbooks.FetchSsrfTest do
  @moduledoc """
  The agent `fetch` tool must not become an SSRF pivot. It now delegates to
  Workbooks.NetGuard (the shared egress floor — wb-dmk1), so the deep IP-range
  matrix is pinned in net_guard_test / broker_net_e2e_test; here we pin the
  AGENT-FACING contract: the fetch tool refuses internal/metadata targets.
  Deterministic — IP-literal hosts need no DNS.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Agent

  defp fetch(url), do: elem(Agent.__exec_one_for_test__(%{name: "fetch", args: %{"url" => url}}, %{tenant: "t"}), 0)

  test "the fetch tool blocks cloud-metadata + loopback + private IP literals" do
    for url <- [
          "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
          "http://127.0.0.1:4000/api/sessions",
          "http://10.0.0.5/internal",
          "http://192.168.1.1/admin",
          "http://172.16.0.9/x"
        ] do
      out = fetch(url)
      assert out =~ "blocked" or out =~ "SSRF", "expected #{url} blocked, got: #{out}"
    end
  end
end

defmodule Workbooks.FetchMissingUrlTest do
  use ExUnit.Case, async: true
  alias Workbooks.Agent
  defp fetch(args), do: elem(Agent.__exec_one_for_test__(%{name: "fetch", args: args}, %{tenant: "t"}), 0)

  test "missing or empty url → clean error, not a crash" do
    assert fetch(%{}) =~ "no url given"
    assert fetch(%{"url" => ""}) =~ "no url given"
    assert fetch(%{"url" => nil}) =~ "no url given"
  end
end

defmodule Workbooks.BrowseFetchSsrfTest do
  @moduledoc """
  The NATIVE fetch/crawl path (Browse.Fetch.get → the default crawl provider,
  what POST /api/browse mode:crawl uses) must enforce the SSRF floor too — once
  it didn't (only the headless path did), so a crawl could reach 169.254.169.254.
  A blocked URL returns {:error, :blocked} BEFORE any connection — deterministic,
  no DNS for IP literals, no network.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Browse.Fetch

  # NOTE: loopback (127.0.0.1) is exempted in :test builds ONLY (compile-time, so
  # prod/dev releases stay strict) so integration tests can crawl a local fixture
  # server — see Browse.Fetch @allow_test_loopback. Loopback-at-the-floor blocking
  # is covered by net_guard_test. Here we pin the targets blocked in ALL builds:
  # cloud metadata + RFC1918 (the real SSRF pivots), which the exemption never touches.
  test "Browse.Fetch.get refuses metadata + private IP literals (blocked in all builds)" do
    for url <- [
          "http://169.254.169.254/latest/meta-data/",
          "http://10.0.0.5/x",
          "http://192.168.1.1/admin",
          "http://172.16.0.9/y"
        ] do
      assert Fetch.get(url) == {:error, :blocked}, "expected #{url} SSRF-blocked"
    end
  end
end
