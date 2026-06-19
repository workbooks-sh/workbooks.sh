defmodule Nexus.ServerBootTest do
  use ExUnit.Case, async: false

  test "GET /health returns 200 (unauthenticated) and identifies the service" do
    port = 4587
    start_supervised!({Nexus.Server, root: File.cwd!(), port: port})
    :inets.start()
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}/health", []}, [], [])

    assert code == 200
    assert to_string(body) =~ ~s("status":"ok")
    assert to_string(body) =~ ~s("service":"nexus")
  end

  test "write_discovery publishes runtime.json {port,token,scheme,...} when WB_DESKTOP_DIR is set" do
    dir = Path.join(System.tmp_dir!(), "disco_#{System.unique_integer([:positive])}")
    System.put_env("WB_DESKTOP_DIR", dir)
    {:ok, path} = Nexus.Desktop.write_discovery(4587)
    data = File.read!(path) |> Jason.decode!()
    assert data["port"] == 4587
    assert data["scheme"] == "http"
    assert data["host"] == "127.0.0.1"
    assert is_binary(data["token"]) and byte_size(data["token"]) > 10
    assert data["token"] == Nexus.Desktop.token()
  after
    System.delete_env("WB_DESKTOP_DIR")
  end

  test "write_discovery is a no-op when not booted by the desktop" do
    System.delete_env("WB_DESKTOP_DIR")
    assert Nexus.Desktop.write_discovery(4587) == :skip
  end
end
