defmodule Workbooks.FlyMachinesTest do
  use ExUnit.Case, async: true
  alias Workbooks.FlyMachines

  @token "fly_secret_TOKEN_should_never_leak"

  describe "build_request/4 (pure construction, no network)" do
    test "create_app targets the fixed host with a Bearer header and JSON body" do
      {method, url, headers, body} =
        FlyMachines.build_request(:post, ["apps"], %{"app_name" => "nx-1", "org_slug" => "acme"},
          token: @token
        )

      assert method == :post
      assert url == "https://api.machines.dev/v1/apps"
      # The token is injected only in the private HTTP layer, never in this pure
      # return value — build_request carries NO authorization header.
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"app_name" => "nx-1", "org_slug" => "acme"}
    end

    test "create_machine wraps config and hits the app's machines path" do
      {method, url, _h, body} =
        FlyMachines.build_request(:post, ["apps", "nx-1", "machines"], %{"config" => %{"image" => "x"}},
          token: @token
        )

      assert method == :post
      assert url == "https://api.machines.dev/v1/apps/nx-1/machines"
      assert Jason.decode!(body) == %{"config" => %{"image" => "x"}}
    end

    test "start/stop/destroy/get build the expected method+url" do
      assert {:post, "https://api.machines.dev/v1/apps/a/machines/m/start", _, ""} =
               FlyMachines.build_request(:post, ["apps", "a", "machines", "m", "start"], nil, token: @token)

      assert {:post, "https://api.machines.dev/v1/apps/a/machines/m/stop", _, ""} =
               FlyMachines.build_request(:post, ["apps", "a", "machines", "m", "stop"], nil, token: @token)

      assert {:delete, "https://api.machines.dev/v1/apps/a/machines/m?force=true", _, ""} =
               FlyMachines.build_request(:delete, ["apps", "a", "machines", "m?force=true"], nil, token: @token)

      assert {:get, "https://api.machines.dev/v1/apps/a/machines/m", _, ""} =
               FlyMachines.build_request(:get, ["apps", "a", "machines", "m"], nil, token: @token)
    end

    test "GET request carries no content-type and an empty body" do
      {_m, _u, headers, body} = FlyMachines.build_request(:get, ["apps", "a", "machines"], nil, token: @token)
      assert body == ""
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
    end
  end

  describe "HTTP layer is injectable; error mapping" do
    defp ok_http(status, resp) do
      fn _m, _u, _h, _b -> {:ok, {status, resp}} end
    end

    test "2xx → {:ok, decoded}" do
      http = ok_http(200, ~s({"id":"m-123","state":"started"}))
      assert {:ok, %{"id" => "m-123", "state" => "started"}} =
               FlyMachines.start_machine("app", "m-123", http: http, token: @token)
    end

    test "non-2xx → {:error, {status, body}}, never raises" do
      http = ok_http(422, ~s({"error":"unprocessable"}))
      assert {:error, {422, %{"error" => "unprocessable"}}} =
               FlyMachines.create_app("nx", "acme", http: http, token: @token)
    end

    test "transport error is propagated as {:error, reason}" do
      http = fn _m, _u, _h, _b -> {:error, :timeout} end
      assert {:error, :timeout} = FlyMachines.list_machines("app", http: http, token: @token)
    end
  end

  describe "id validation (SSRF / path-escape floor)" do
    test "a slash / dot-segment / query char in an id fails closed" do
      http = fn _m, _u, _h, _b -> flunk("should not have dispatched") end

      for bad <- ["../other", "a/b", "..", "a?force=true", "a#frag", "a b", ""] do
        assert {:error, :invalid_id} = FlyMachines.get_machine(bad, "m", http: http)
        assert {:error, :invalid_id} = FlyMachines.get_machine("app", bad, http: http)
      end
    end

    test "api host is a fixed constant, not caller-supplied" do
      assert FlyMachines.api_host() == "https://api.machines.dev/v1"
    end
  end

  describe "token never leaks" do
    test "token is absent from every returned value (ok, error, transport-error)" do
      System.put_env("FLY_API_TOKEN", @token)
      on_exit(fn -> System.delete_env("FLY_API_TOKEN") end)

      results = [
        FlyMachines.start_machine("app", "m", http: ok_http(200, ~s({"ok":true}))),
        FlyMachines.create_app("nx", "acme", http: ok_http(500, ~s({"error":"boom"}))),
        FlyMachines.get_machine("app", "m", http: fn _m, _u, _h, _b -> {:error, :nxdomain} end),
        FlyMachines.get_machine("../bad", "m", http: fn _, _, _, _ -> :ok end)
      ]

      for r <- results do
        refute inspect(r) =~ @token
        refute inspect(r) =~ "Bearer"
      end
    end

    test "build_request output contains no token at all (url, headers, body)" do
      tuple = FlyMachines.build_request(:get, ["apps", "a"], %{"k" => "v"}, token: @token)
      refute inspect(tuple) =~ @token
      refute inspect(tuple) =~ "Bearer"
      refute inspect(tuple) =~ "authorization"
    end
  end

  # BLOCKER-1 regression lock: the Fly token (org master credential) must travel
  # over VERIFIED TLS. Pre-fix `:httpc.request` ran with no :ssl options
  # (verify_none) → MITM-stealable. These assertions fail against that logic.
  describe "TLS is verified (BLOCKER-1: no MITM of the Fly token)" do
    test "http_options pin verify_peer, a non-empty CA store, and the api.machines.dev SNI" do
      opts = FlyMachines.http_options()
      ssl = Keyword.fetch!(opts, :ssl)

      assert Keyword.get(ssl, :verify) == :verify_peer
      cacerts = Keyword.get(ssl, :cacerts)
      assert is_list(cacerts) and cacerts != []
      assert Keyword.get(ssl, :server_name_indication) == ~c"api.machines.dev"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end
  end
end
