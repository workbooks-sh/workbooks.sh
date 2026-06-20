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

  test "imports/2 builds the Wasmex.Components import map (path-scoped, grant-filtered)" do
    imports = Caps.imports({"acme", "app", "tk"}, [:store, :load])
    assert Map.keys(imports) |> Enum.sort() == ["load", "store"]
    assert {:fn, store_fn} = imports["store"]
    assert is_function(store_fn, 2)
    assert {:fn, load_fn} = imports["load"]
    assert is_function(load_fn, 1)
    refute Map.has_key?(imports, "fetch")
  end

  test "imports are path-scoped through the built fns" do
    a = Caps.imports({"globex", "app", "a"}, [:store, :load])
    b = Caps.imports({"globex", "app", "b"}, [:store, :load])
    {:fn, a_store} = a["store"]
    {:fn, a_load} = a["load"]
    {:fn, b_load} = b["load"]

    a_store.("k", "secret-a")
    assert a_load.("k") == "secret-a"
    assert b_load.("k") == ""
  end
end
