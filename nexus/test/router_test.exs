defmodule Nexus.RouterTest do
  use ExUnit.Case, async: false
  alias Nexus.Router

  defmodule Sample do
    use Nexus.Router

    route "GET  /api/orders", :list
    route "POST /api/orders", :create
    route "GET  /api/orders/:id", :show

    def list(_req), do: %{orders: [1, 2]}
    def create(req), do: {201, %{created: req.body}}
    def show(req), do: %{id: req.params["id"]}
  end

  setup do
    Router.reset()
    Router.install(Sample)
    :ok
  end

  test "use Nexus.Router bakes declared routes into __nexus_routes__/0 (survives the compile cache)" do
    specs = Enum.map(Sample.__nexus_routes__(), &elem(&1, 0))
    assert "GET  /api/orders" in specs
    assert length(Sample.__nexus_routes__()) == 3
  end

  test "parse splits method + path, defaults GET, normalizes leading slash" do
    assert Router.parse("GET /a/b") == {"GET", "/a/b"}
    assert Router.parse("post  /a") == {"POST", "/a"}
    assert Router.parse("/a/b") == {"GET", "/a/b"}
  end

  test "matches literal routes by method + path" do
    assert {Sample, :list, _pol, %{}} = Router.match("GET", "/api/orders")
    assert {Sample, :create, _pol, %{}} = Router.match("POST", "/api/orders")
    assert Router.match("DELETE", "/api/orders") == nil
    assert Router.match("GET", "/nope") == nil
  end

  test "captures :param segments" do
    assert {Sample, :show, _pol, %{"id" => "42"}} = Router.match("GET", "/api/orders/42")
  end

  test "most-specific (fewest captures) wins" do
    Router.add("GET /api/orders/new", Sample, :list)
    assert {Sample, :list, _pol, %{}} = Router.match("GET", "/api/orders/new")
  end

  test "carries a declared auth policy through to match" do
    Router.add("GET /api/secret", Sample, :list, :admin)
    assert {Sample, :list, :admin, %{}} = Router.match("GET", "/api/secret")
  end

  test "dispatch normalizes returns into {status, ctype, body}" do
    assert {200, "application/json", body} = Router.dispatch(Sample, :list, %{})
    assert body == ~s({"orders":[1,2]})
    assert {201, "application/json", _} = Router.dispatch(Sample, :create, %{body: %{a: 1}})
    assert {200, "application/json", ~s({"id":"7"})} = Router.dispatch(Sample, :show, %{params: %{"id" => "7"}})
  end

  test "a raising handler yields a 500 JSON error, never a crash" do
    defmodule Boom do
      def go(_), do: raise("kaboom")
    end

    assert {500, "application/json", body} = Router.dispatch(Boom, :go, %{})
    assert body =~ "kaboom"
  end
end
