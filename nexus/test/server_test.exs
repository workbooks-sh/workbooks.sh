defmodule Nexus.ServerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "srv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.work"), "# Shop\n\nresource Item do\n  name :text\n  price :int\nend\n\nshow Item\n")

    mod =
      dir |> Path.join("a.work") |> File.read!() |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code)) |> Nexus.Resource.compile()

    Nexus.Store.clear(mod)
    Nexus.Store.create(mod, %{name: "Soup", price: 99})

    port = 4300 + System.unique_integer([:positive]) |> rem(500)
    {:ok, pid} = Nexus.Server.start_link(root: dir, port: port)
    :inets.start()
    on_exit(fn -> Process.exit(pid, :kill); File.rm_rf!(dir) end)
    {:ok, port: port, mod: mod}
  end

  defp get(port, path) do
    {:ok, {{_, status, _}, _h, body}} = :httpc.request(~c"http://127.0.0.1:#{port}#{path}")
    {status, to_string(body)}
  end

  test "GET / serves the SSR'd workbook with live data", %{port: port} do
    {200, html} = get(port, "/")
    assert html =~ ~s(<table class="data" data-resource="Item">)
    assert html =~ "Soup" and html =~ "99"
  end

  test "GET /data/:resource serves the rows as JSON (the server data backend)", %{port: port} do
    {200, json} = get(port, "/data/Item")
    assert {:ok, [%{"name" => "Soup", "price" => 99}]} = Jason.decode(json)
  end

  test "GET /data of an unknown resource is an empty array, not an error", %{port: port} do
    {200, json} = get(port, "/data/Ghost")
    assert json == "[]"
  end

  test "the Bearer auth adapter gates /data — 401 without the bearer, 200 with", %{port: port} do
    Application.put_env(:nexus, :auth, Nexus.Auth.Bearer)
    System.put_env("NEXUS_DATA_TOKEN", "s3cret")

    on_exit(fn ->
      Application.put_env(:nexus, :auth, Nexus.Auth.None)
      System.delete_env("NEXUS_DATA_TOKEN")
    end)

    {:ok, {{_, no_auth, _}, _, _}} = :httpc.request(~c"http://127.0.0.1:#{port}/data/Item")
    assert no_auth == 401

    req = {~c"http://127.0.0.1:#{port}/data/Item", [{~c"authorization", ~c"Bearer s3cret"}]}
    {:ok, {{_, ok, _}, _, _}} = :httpc.request(:get, req, [], [])
    assert ok == 200
  end

  test "MULTI-TENANT: each JWT tenant sees only its own /data rows (end-to-end isolation)",
       %{port: port, mod: mod} do
    Application.put_env(:nexus, :auth, Nexus.Auth.Jwt)
    Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org")
    on_exit(fn ->
      Application.put_env(:nexus, :auth, Nexus.Auth.None)
      Application.delete_env(:nexus, Nexus.Auth.Jwt)
    end)

    # seed per-tenant data (the setup row is on "default" — invisible to t1/t2)
    Nexus.Store.create(mod, %{name: "AcmeWidget", price: 1}, "t1")
    Nexus.Store.create(mod, %{name: "GlobexGizmo", price: 2}, "t2")

    jwt = fn org ->
      {_, t} = JOSE.JWK.from_oct("shh") |> JOSE.JWT.sign(%{"alg" => "HS256"}, %{"org" => org, "exp" => System.os_time(:second) + 60}) |> JOSE.JWS.compact()
      t
    end

    fetch = fn org ->
      req = {~c"http://127.0.0.1:#{port}/data/Item", [{~c"authorization", ~c"Bearer #{jwt.(org)}"}]}
      {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, req, [], [])
      Jason.decode!(to_string(body)) |> Enum.map(& &1["name"])
    end

    assert fetch.("t1") == ["AcmeWidget"]
    assert fetch.("t2") == ["GlobexGizmo"]
    # no JWT → 401
    {:ok, {{_, status, _}, _, _}} = :httpc.request(~c"http://127.0.0.1:#{port}/data/Item")
    assert status == 401
  end

  test "served page is live-mode and /data reflects data changed after the page was cached",
       %{port: port, mod: mod} do
    {200, html} = get(port, "/")
    # the client prefers fresh /data over the baked initial paint (server posture)
    assert html =~ "_live: true"

    # add a row AFTER the SSR shell is cached — /data must still return it (it's live, not cached)
    Nexus.Store.create(mod, %{name: "Fresh", price: 1})
    {200, json} = get(port, "/data/Item")
    assert {:ok, rows} = Jason.decode(json)
    assert Enum.any?(rows, &(&1["name"] == "Fresh"))
  end

  test "SSR CACHE LEAK: multi-tenant shell bakes NO data; single-tenant shell does", %{port: port, mod: mod} do
    Application.put_env(:nexus, :auth, Nexus.Auth.Jwt)
    Application.put_env(:nexus, Nexus.Auth.Jwt, secret: "shh", tenant_claim: "org")
    on_exit(fn ->
      Application.put_env(:nexus, :auth, Nexus.Auth.None)
      Application.delete_env(:nexus, Nexus.Auth.Jwt)
      # drop the cached shells so later tests rebuild cleanly
      if :ets.whereis(:nexus_server_cache) != :undefined, do: :ets.delete_all_objects(:nexus_server_cache)
    end)

    if :ets.whereis(:nexus_server_cache) != :undefined, do: :ets.delete_all_objects(:nexus_server_cache)
    Nexus.Store.create(mod, %{name: "SecretAcme", price: 7}, "t1")

    jwt = fn org ->
      {_, t} = JOSE.JWK.from_oct("shh") |> JOSE.JWT.sign(%{"alg" => "HS256"}, %{"org" => org, "exp" => System.os_time(:second) + 60}) |> JOSE.JWS.compact()
      t
    end

    home = fn org ->
      req = {~c"http://127.0.0.1:#{port}/", [{~c"authorization", ~c"Bearer #{jwt.(org)}"}]}
      {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, req, [], [])
      to_string(body)
    end

    # The shared/cached multi-tenant shell must inline NO tenant rows — neither t1's secret
    # data nor the setup "default" row ("Soup"). It is bake:false and tenant-agnostic.
    h1 = home.("t1")
    refute h1 =~ "SecretAcme"
    refute h1 =~ "Soup"
    # t2 gets the very same shell (no t1 bleed); confirm cache served identical bytes.
    assert home.("t2") == h1
  end
end
