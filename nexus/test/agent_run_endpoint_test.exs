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
    assert Jason.decode!(body)["error"] == "task or prompt required"
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

defmodule Nexus.AgentRunAliasTest do
  use ExUnit.Case, async: false

  setup do
    port = 4594
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, port: port}
  end

  defp post(port, body) do
    :httpc.request(:post, {~c"http://127.0.0.1:#{port}/api/run", [], ~c"application/json", body}, [], body_format: :binary)
  end

  test "accepts `prompt` as an alias for `task` + ignores desktop extras (agent_slug/workdir/skills)", %{port: port} do
    # No LLM key in test → the run fails fast, but the point is the body shape is ACCEPTED (200, not 422).
    body = Jason.encode!(%{"prompt" => "hi", "agent_slug" => "x", "workdir" => "/w", "skills" => ["a"], "timeout_ms" => 1000})
    {:ok, {{_, code, _}, _h, resp}} = post(port, body)
    assert code == 200
    assert is_map(Jason.decode!(resp))
  end

  test "neither task nor prompt → 422", %{port: port} do
    {:ok, {{_, code, _}, _h, _b}} = post(port, Jason.encode!(%{"agent_slug" => "x"}))
    assert code == 422
  end
end
