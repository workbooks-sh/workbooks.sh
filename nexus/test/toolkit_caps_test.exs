defmodule Nexus.Toolkit.CapsTest do
  use ExUnit.Case, async: true
  alias Nexus.Toolkit.Caps

  test "path_key composes the partition path" do
    assert Caps.path_key({"acme", "orders", "stripe"}) == "acme/orders/stripe"
  end

  test "bind exposes ONLY granted caps (deny-by-default)" do
    impls = Caps.bind({"acme", "app", "tk"}, [:store, :load, :emit])
    assert Map.keys(impls) |> Enum.sort() == [:emit, :load, :store]
    refute Map.has_key?(impls, :fetch)
    refute Map.has_key?(impls, :complete)
  end

  test "store/load are PATH-SCOPED — one path cannot read another's data" do
    a = Caps.bind({"acme", "app", "a"}, [:store, :load])
    b = Caps.bind({"acme", "app", "b"}, [:store, :load])

    a.store.("k", "value-a")
    b.store.("k", "value-b")

    assert a.load.("k") == "value-a"
    assert b.load.("k") == "value-b"
    # a different operator entirely is also isolated
    c = Caps.bind({"globex", "app", "a"}, [:store, :load])
    assert c.load.("k") == ""
  end

  test "host_js binds only granted caps to the engine import globals" do
    js = Caps.host_js([:store, :emit])
    assert js =~ "store: __cap_store"
    assert js =~ "emit: __cap_emit"
    refute js =~ "fetch:"
    refute js =~ "complete:"
  end

  test "wit emits the import interface for the granted caps (kebab-cased)" do
    wit = Caps.wit([:cache_get, :store])
    assert wit =~ "interface toolkit-caps {"
    assert wit =~ "cache-get: func(key: string) -> string;"
    assert wit =~ "store: func(key: string, val: string);"
  end

  test "driver uses the cap host binding when :grants is given" do
    {:ok, js} = Nexus.Toolkit.Js.runnable("def f(x), do: x")
    src = Nexus.Toolkit.Js.driver(js, "f", [1], grants: [:emit, :store])
    assert src =~ "emit: __cap_emit"
    assert src =~ "store: __cap_store"
  end

  test "imports/2 builds the interface-nested Wasmex.Components import map (kebab, grant-filtered)" do
    %{} = imports = Caps.imports({"acme", "app", "tk"}, [:store, :load, :cache_get])
    iface = imports[Nexus.JsEngine.caps_iface()]
    assert Map.keys(iface) |> Enum.sort() == ["cache-get", "load", "store"]
    assert {:fn, store_fn} = iface["store"]
    assert is_function(store_fn, 2)
    refute Map.has_key?(iface, "fetch")
  end

  # End-to-end through the REAL cap-enabled StarlingMonkey eval-host (when the engine wasm is present):
  # a cap toolkit invoked on two paths — path A's store must be invisible to path B.
  @tag :js_engine
  test "cap toolkit runs through the eval-host with path-scoped isolation" do
    if Nexus.JsEngine.available?() do
      src = "def save(k, v) do\n  store(k, v)\n  load(k)\nend\ndef get(k), do: load(k)"
      Nexus.Toolkit.Js.register("kvtest", %{name: "kvtest", js: elem(Nexus.Toolkit.Js.runnable(src), 1), exports: []})
      a = [path: {"t", "app", "a"}, grants: [:store, :load, :emit]]
      b = [path: {"t", "app", "b"}, grants: [:store, :load, :emit]]

      assert {:ok, "hi"} = Nexus.Toolkit.Js.invoke("kvtest", "save", ["a", "hi"], a)
      assert {:ok, "hi"} = Nexus.Toolkit.Js.invoke("kvtest", "get", ["a"], a)
      assert {:ok, ""} = Nexus.Toolkit.Js.invoke("kvtest", "get", ["a"], b)
    end
  end

  test "imports are path-scoped through the built fns" do
    iface = Nexus.JsEngine.caps_iface()
    a = Caps.imports({"globex", "app", "a"}, [:store, :load])[iface]
    b = Caps.imports({"globex", "app", "b"}, [:store, :load])[iface]
    {:fn, a_store} = a["store"]
    {:fn, a_load} = a["load"]
    {:fn, b_load} = b["load"]

    a_store.("k", "secret-a")
    assert a_load.("k") == "secret-a"
    assert b_load.("k") == ""
  end
end
