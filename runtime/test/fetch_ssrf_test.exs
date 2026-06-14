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
