defmodule Workbooks.NeonTest do
  use ExUnit.Case, async: true
  alias Workbooks.Neon

  @key "neon_secret_KEY_should_never_leak"

  describe "build_request/4 (pure construction, no network)" do
    test "create_project targets the fixed host with a JSON body and NO auth header" do
      {method, url, headers, body} =
        Neon.build_request(:post, ["projects"], %{"project" => %{"name" => "tenant-1"}},
          token: @key
        )

      assert method == :post
      assert url == "https://console.neon.tech/api/v2/projects"
      # The key is injected only in the private HTTP layer, never in this pure
      # return value — build_request carries NO authorization header.
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"project" => %{"name" => "tenant-1"}}
    end

    test "create_project (full verb) builds POST /projects with the project wrapper" do
      http = fn :post, url, _h, body ->
        assert url == "https://console.neon.tech/api/v2/projects"
        assert Jason.decode!(body) == %{"project" => %{"name" => "tenant-1"}}
        {:ok, {201, ~s({"project":{"id":"p-1"}})}}
      end

      assert {:ok, %{"project" => %{"id" => "p-1"}}} =
               Neon.create_project("tenant-1", http: http, token: @key)
    end

    test "get_connection_uri builds GET with required database_name+role_name+pooled query" do
      http = fn :get, url, _h, "" ->
        assert String.starts_with?(
                 url,
                 "https://console.neon.tech/api/v2/projects/p-1/connection_uri?"
               )

        q = URI.decode_query(URI.parse(url).query)
        assert q["database_name"] == "neondb"
        assert q["role_name"] == "neondb_owner"
        assert q["pooled"] == "true"
        {:ok, {200, ~s({"uri":"postgres://x"})}}
      end

      assert {:ok, %{"uri" => "postgres://x"}} =
               Neon.get_connection_uri("p-1", http: http, token: @key)
    end

    test "get_connection_uri honors pooled:false and custom db/role" do
      http = fn :get, url, _h, "" ->
        q = URI.decode_query(URI.parse(url).query)
        assert q["pooled"] == "false"
        assert q["database_name"] == "appdb"
        assert q["role_name"] == "appuser"
        {:ok, {200, "{}"}}
      end

      assert {:ok, %{}} =
               Neon.get_connection_uri("p-1",
                 pooled: false,
                 database_name: "appdb",
                 role_name: "appuser",
                 http: http,
                 token: @key
               )
    end

    test "delete_project builds DELETE /projects/:id with empty body" do
      http = fn :delete, url, _h, "" ->
        assert url == "https://console.neon.tech/api/v2/projects/p-1"
        {:ok, {200, ~s({"project":{"id":"p-1"}})}}
      end

      assert {:ok, %{"project" => %{"id" => "p-1"}}} =
               Neon.delete_project("p-1", http: http, token: @key)
    end

    test "GET request carries no content-type and an empty body" do
      {_m, _u, headers, body} =
        Neon.build_request(:get, ["projects", "p-1"], nil, token: @key)

      assert body == ""
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
    end
  end

  describe "HTTP layer is injectable; error mapping" do
    defp ok_http(status, resp), do: fn _m, _u, _h, _b -> {:ok, {status, resp}} end

    test "2xx → {:ok, decoded}" do
      http = ok_http(201, ~s({"project":{"id":"p-9"}}))
      assert {:ok, %{"project" => %{"id" => "p-9"}}} =
               Neon.create_project("nx", http: http, token: @key)
    end

    test "non-2xx → {:error, {status, body}}, never raises" do
      http = ok_http(422, ~s({"error":"unprocessable"}))
      assert {:error, {422, %{"error" => "unprocessable"}}} =
               Neon.create_project("nx", http: http, token: @key)
    end

    test "transport error is propagated as {:error, reason}" do
      http = fn _m, _u, _h, _b -> {:error, :timeout} end
      assert {:error, :timeout} = Neon.delete_project("p-1", http: http, token: @key)
    end
  end

  describe "id validation (SSRF / path-escape floor)" do
    test "a slash / dot-segment / query char in a project_id fails closed" do
      http = fn _m, _u, _h, _b -> flunk("should not have dispatched") end

      for bad <- ["../other", "a/b", "..", "a?force=true", "a#frag", "a b", ""] do
        assert {:error, :invalid_id} = Neon.get_connection_uri(bad, http: http)
        assert {:error, :invalid_id} = Neon.delete_project(bad, http: http)
      end
    end

    test "api host is a fixed constant, not caller-supplied" do
      assert Neon.api_host() == "https://console.neon.tech/api/v2"
    end
  end

  describe "key never leaks" do
    test "key is absent from every returned value (ok, error, transport-error, invalid)" do
      System.put_env("NEON_API_KEY", @key)
      on_exit(fn -> System.delete_env("NEON_API_KEY") end)

      results = [
        Neon.create_project("nx", http: ok_http(201, ~s({"ok":true}))),
        Neon.delete_project("p-1", http: ok_http(500, ~s({"error":"boom"}))),
        Neon.get_connection_uri("p-1", http: fn _m, _u, _h, _b -> {:error, :nxdomain} end),
        Neon.delete_project("../bad", http: fn _, _, _, _ -> :ok end)
      ]

      for r <- results do
        refute inspect(r) =~ @key
        refute inspect(r) =~ "Bearer"
      end
    end

    test "build_request output contains no key at all (url, headers, body)" do
      tuple = Neon.build_request(:post, ["projects"], %{"k" => "v"}, token: @key)
      refute inspect(tuple) =~ @key
      refute inspect(tuple) =~ "Bearer"
      refute inspect(tuple) =~ "authorization"
    end
  end

  # CRITICAL regression lock (Phase-2a): the Neon API key (org master credential)
  # must travel over VERIFIED TLS. With no :ssl options :httpc runs verify_none →
  # MITM-stealable. These assertions fail against that logic.
  describe "TLS is verified (no MITM of the Neon API key)" do
    test "http_options pin verify_peer, a non-empty CA store, and the console.neon.tech SNI" do
      opts = Neon.http_options()
      ssl = Keyword.fetch!(opts, :ssl)

      assert Keyword.get(ssl, :verify) == :verify_peer
      cacerts = Keyword.get(ssl, :cacerts)
      assert is_list(cacerts) and cacerts != []
      assert Keyword.get(ssl, :server_name_indication) == ~c"console.neon.tech"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end
  end
end
