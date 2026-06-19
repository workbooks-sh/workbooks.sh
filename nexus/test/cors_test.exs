defmodule Nexus.CorsTest do
  use ExUnit.Case, async: false

  setup do
    port = 4596
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, port: port}
  end

  test "OPTIONS preflight → 204 with CORS headers, NO auth required", %{port: port} do
    {:ok, {{_, code, _}, h, _}} =
      :httpc.request(:options, {~c"http://127.0.0.1:#{port}/api/platform/nexuses", []}, [], [])
    assert code == 204
    hdrs = Map.new(h, fn {k, v} -> {to_string(k) |> String.downcase(), to_string(v)} end)
    assert hdrs["access-control-allow-origin"] == "*"
    assert hdrs["access-control-allow-headers"] =~ "authorization"
  end

  test "a real response carries Access-Control-Allow-Origin", %{port: port} do
    {:ok, {{_, 200, _}, h, _}} = :httpc.request(:get, {~c"http://127.0.0.1:#{port}/health", []}, [], [])
    hdrs = Map.new(h, fn {k, v} -> {to_string(k) |> String.downcase(), to_string(v)} end)
    assert hdrs["access-control-allow-origin"] == "*"
  end
end
