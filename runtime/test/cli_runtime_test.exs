defmodule CliRuntimeTest do
  @moduledoc "wb-82g: the `wb rt` CLI as an RCP HTTP client — target resolution, dispatch, exit codes."
  use ExUnit.Case, async: false

  alias Workbooks.CLI.Runtime

  # A fake requester: records the call, returns a canned {:ok, code, body} | {:error, _}.
  defp faker(code, body) do
    fn method, url, reqbody, token ->
      send(self(), {:req, method, url, reqbody, token})
      if code == :neterr, do: {:error, "econnrefused"}, else: {:ok, code, body}
    end
  end

  describe "target resolution" do
    test "env WB_RUNTIME_URL/WB_TOKEN wins" do
      System.put_env("WB_RUNTIME_URL", "https://rt.example.com/")
      System.put_env("WB_TOKEN", "tok-xyz")
      on_exit(fn -> System.delete_env("WB_RUNTIME_URL"); System.delete_env("WB_TOKEN") end)

      assert {:ok, %{url: "https://rt.example.com", token: "tok-xyz", source: "env"}} = Runtime.target()
    end

    test "falls back to the discovery file" do
      dir = Path.join(System.tmp_dir!(), "wb_disco_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "runtime.json"), Jason.encode!(%{port: 4321, token: "disco-tok", scheme: "http"}))
      System.put_env("WB_DESKTOP_DIR", dir)
      System.delete_env("WB_RUNTIME_URL")
      on_exit(fn -> System.delete_env("WB_DESKTOP_DIR"); File.rm_rf!(dir) end)

      assert {:ok, %{url: "http://127.0.0.1:4321", token: "disco-tok", source: "discovery"}} = Runtime.target()
    end

    test "no env + no discovery → actionable error" do
      System.delete_env("WB_RUNTIME_URL")
      System.put_env("WB_DESKTOP_DIR", Path.join(System.tmp_dir!(), "nope_#{System.unique_integer([:positive])}"))
      on_exit(fn -> System.delete_env("WB_DESKTOP_DIR") end)

      assert {:error, msg} = Runtime.target()
      assert msg =~ "WB_RUNTIME_URL"
    end
  end

  describe "rt commands (injected requester)" do
    setup do
      System.put_env("WB_RUNTIME_URL", "http://127.0.0.1:9999")
      System.put_env("WB_TOKEN", "T")
      on_exit(fn -> System.delete_env("WB_RUNTIME_URL"); System.delete_env("WB_TOKEN") end)
      :ok
    end

    test "status hits the well-known handshake and annotates the target" do
      caps = %{"rcp" => "1", "tenancy" => "single"}
      {out, failed?} = Runtime.run(["status"], faker(200, caps))
      refute failed?
      assert_received {:req, :get, "http://127.0.0.1:9999/.well-known/workbooks-runtime", nil, "T"}
      assert out =~ ~s("rcp": "1")
      assert out =~ "_target"
    end

    test "get attaches the bearer + normalizes the path" do
      {_out, failed?} = Runtime.run(["get", "api/workbooks"], faker(200, %{"ok" => true}))
      refute failed?
      assert_received {:req, :get, "http://127.0.0.1:9999/api/workbooks", nil, "T"}
    end

    test "post sends the body" do
      {_out, failed?} = Runtime.run(["post", "/api/x", ~s({"a":1})], faker(200, %{}))
      refute failed?
      assert_received {:req, :post, "http://127.0.0.1:9999/api/x", ~s({"a":1}), "T"}
    end

    test "non-2xx surfaces the error envelope and a failing exit" do
      env = %{"error" => %{"code" => "tenant_required", "message" => "nope"}}
      {out, failed?} = Runtime.run(["get", "/instances"], faker(401, env))
      assert failed?
      assert out =~ "tenant_required"
      assert out =~ "HTTP 401"
    end

    test "network error → failing exit" do
      {out, failed?} = Runtime.run(["get", "/x"], faker(:neterr, nil))
      assert failed?
      assert out =~ "request failed"
    end

    test "unknown subcommand → usage + failing exit" do
      {out, failed?} = Runtime.run(["wat"], faker(200, %{}))
      assert failed?
      assert out =~ "wb rt"
    end
  end
end
