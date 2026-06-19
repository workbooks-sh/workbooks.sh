defmodule Nexus.AgentStreamTest do
  use ExUnit.Case, async: false

  # The desktop's streaming agent-run target. We assert the SSE framing (a real run needs an LLM key);
  # with no key the run fails fast but must still stream well-formed error+end frames. async:false —
  # starts a server on a fixed port.
  setup do
    port = 4595
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, port: port}
  end

  defp post(port, path, body) do
    :httpc.request(:post, {~c"http://127.0.0.1:#{port}#{path}", [], ~c"application/json", body}, [], body_format: :binary)
  end

  test "POST /api/run/stream with no task → 422", %{port: port} do
    {:ok, {{_, code, _}, _h, body}} = post(port, "/api/run/stream", Jason.encode!(%{"system" => "x"}))
    assert code == 422
    assert Jason.decode!(body)["error"] == "task or prompt required"
  end

  test "POST /api/run/stream with a task → chunked text/event-stream ending in a {type:end} frame", %{port: port} do
    {:ok, {{_, 200, _}, headers, body}} = post(port, "/api/run/stream", Jason.encode!(%{"task" => "hi", "timeout_ms" => 1000}))

    ctype = headers |> Enum.into(%{}, fn {k, v} -> {to_string(k), to_string(v)} end) |> Map.get("content-type", "")
    assert ctype =~ "text/event-stream"

    body = to_string(body)
    assert body =~ "data:"
    # Well-formed: the stream terminates with the end frame (a fail-fast run still streams error→end).
    assert body =~ ~s({"type":"end"})
  end
end
