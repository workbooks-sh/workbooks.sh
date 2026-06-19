defmodule Nexus.AgentRunEndpointTest do
  use ExUnit.Case, async: false

  # The desktop's agent-run target. We test the routing/validation/auth surface (a real run needs an
  # LLM key + is live-verified). async:false — starts a server on a fixed port.
  setup do
    port = 4593
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, port: port}
  end

  defp post(port, path, body) do
    :httpc.request(:post, {~c"http://127.0.0.1:#{port}#{path}", [], ~c"application/json", body}, [], body_format: :binary)
  end

  test "POST /api/run with no task → 422 (validation, no agent invoked)", %{port: port} do
    {:ok, {{_, code, _}, _h, body}} = post(port, "/api/run", Jason.encode!(%{"system" => "x"}))
    assert code == 422
    assert Jason.decode!(body)["error"] == "task required"
  end

  test "POST /api/run with empty task → 422", %{port: port} do
    {:ok, {{_, code, _}, _h, _b}} = post(port, "/api/run", Jason.encode!(%{"task" => ""}))
    assert code == 422
  end

  test "garbage body → 422 (no crash)", %{port: port} do
    {:ok, {{_, code, _}, _h, _b}} = post(port, "/api/run", "not json")
    assert code == 422
  end
end
