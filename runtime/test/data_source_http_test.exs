defmodule Workbooks.DataSourceHttpTest do
  @moduledoc """
  wb-39j.2/.3 — the generic HTTP/JSON data source + credential broker. Makes any
  JSON API a federation source: SELECT … FROM <entity> → GET url → rows. The HTTP
  getter is injectable (opts[:http]) so these run without network.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{DataSource, Federation}
  alias Workbooks.Plugin.Auth

  test "HTTP source extracts rows via #+ROWS_PATH (injected http)" do
    DataSource.register("http-item", Workbooks.DataSource.Http, %{
      "url" => "https://api.test/items",
      "rows_path" => "data.items"
    })

    stub = fn url, _headers ->
      assert url == "https://api.test/items"
      {:ok, ~s|{"data":{"items":[{"id":1,"t":"a"},{"id":2,"t":"b"}]}}|}
    end

    assert {:ok, rows} = Federation.query("SELECT * FROM http-item", http: stub)
    assert length(rows) == 2
    assert hd(rows)["t"] == "a"
  end

  test "auth header is resolved through Plugin.Auth (never raw in the plugin)" do
    DataSource.register("auth-item", Workbooks.DataSource.Http, %{
      "url" => "https://api.test/x",
      "env_keys" => ["FED_TEST_KEY"]
    })

    System.put_env("FED_TEST_KEY", "sekret")

    stub = fn _url, headers ->
      {_, auth} = List.keyfind(headers, ~c"authorization", 0)
      assert to_string(auth) == "Bearer sekret"
      {:ok, "[]"}
    end

    assert {:ok, []} = Federation.query("SELECT * FROM auth-item", http: stub)
    System.delete_env("FED_TEST_KEY")
  end

  test "#+ROWS_PATH absent → the whole body is the row array" do
    DataSource.register("flat-item", Workbooks.DataSource.Http, %{"url" => "https://x"})
    stub = fn _u, _h -> {:ok, ~s|[{"a":1},{"a":2}]|} end
    assert {:ok, [%{"a" => 1}, %{"a" => 2}]} = Federation.query("SELECT * FROM flat-item", http: stub)
  end

  test "http error propagates" do
    DataSource.register("err-item", Workbooks.DataSource.Http, %{"url" => "https://x"})
    stub = fn _u, _h -> {:error, {:http_status, 500}} end
    assert {:error, {:http_status, 500}} = Federation.query("SELECT * FROM err-item", http: stub)
  end

  test "Plugin.Auth: resolver wins over env; env is the fallback; missing → nil" do
    assert Auth.fetch("FED_MISSING_KEY") == nil
    System.put_env("FED_AK", "envval")
    assert Auth.fetch("FED_AK") == "envval"
    assert Auth.fetch("FED_AK", resolver: fn _ -> "broker" end) == "broker"
    assert Auth.fetch("FED_AK", resolver: fn _ -> nil end) == "envval"
    System.delete_env("FED_AK")
  end
end
