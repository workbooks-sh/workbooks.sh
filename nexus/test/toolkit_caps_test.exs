defmodule Nexus.Toolkit.CapsTest do
  # async: false — registers toolkits in the shared global kit registry that another sync test's
  # on_exit (toolkit_test) clears; running serially avoids the cross-test registry race.
  use ExUnit.Case, async: false
  alias Nexus.Toolkit.Caps

  test "path_key composes the partition path" do
    assert Caps.path_key({"acme", "orders", "stripe"}) == "acme/orders/stripe"
  end

  test "dispatch denies ungranted ops (deny-by-default)" do
    resp = Caps.dispatch(~s({"op":"fetch","url":"http://x"}), {"t", "a", "c"}, [:store, :load])
    assert %{"ok" => false, "error" => err} = Jason.decode!(resp)
    assert err =~ "not granted"
  end

  test "dispatch rejects unknown ops + bad requests" do
    assert %{"ok" => false} = Jason.decode!(Caps.dispatch(~s({"op":"rm -rf"}), {"t", "a", "c"}, [:store]))
    assert %{"ok" => false} = Jason.decode!(Caps.dispatch("not json", {"t", "a", "c"}, [:store]))
  end

  test "store/load round-trip is PATH-SCOPED through dispatch" do
    pa = {"caps-disp", "app", "a"}
    pb = {"caps-disp", "app", "b"}
    g = [:store, :load]

    assert %{"ok" => true} = Jason.decode!(Caps.dispatch(~s({"op":"store","key":"k","val":"va"}), pa, g))
    assert %{"ok" => true, "value" => "va"} = Jason.decode!(Caps.dispatch(~s({"op":"load","key":"k"}), pa, g))
    # path b never wrote "k" — isolated
    assert %{"ok" => true, "value" => ""} = Jason.decode!(Caps.dispatch(~s({"op":"load","key":"k"}), pb, g))
  end

  test "host_js binds only granted caps as wrappers over __wbHostCall" do
    js = Caps.host_js([:store, :emit])
    assert js =~ "__wbHostCall"
    assert js =~ "store: (k, v) =>"
    assert js =~ "op:\"store\""
    assert js =~ "emit: (m) =>"
    refute js =~ "fetch:"
    refute js =~ "complete:"
  end

  test "broker/2 is a 1-arg host-call closure bound to path + grants" do
    b = Caps.broker({"b2", "app", "c"}, [:store, :load])
    assert is_function(b, 1)
    assert %{"ok" => true} = Jason.decode!(b.(~s({"op":"store","key":"x","val":"1"})))
    assert %{"ok" => true, "value" => "1"} = Jason.decode!(b.(~s({"op":"load","key":"x"})))
  end

  # End-to-end through the REAL StarlingMonkey eval-host over the shared host-call seam (when present):
  # a cap toolkit invoked on two paths — path A's store must be invisible to path B.
  @tag :js_engine
  test "cap toolkit runs through the eval-host with path-scoped isolation" do
    if Nexus.JsEngine.available?() do
      src = "def save(k, v) do\n  store(k, v)\n  load(k)\nend\ndef get(k), do: load(k)"
      Nexus.Toolkit.Js.register("kvtest", %{name: "kvtest", js: elem(Nexus.Toolkit.Js.runnable(src), 1), exports: []})
      a = [path: {"e2e", "app", "a"}, grants: [:store, :load, :emit]]
      b = [path: {"e2e", "app", "b"}, grants: [:store, :load, :emit]]

      assert {:ok, "hi"} = Nexus.Toolkit.Js.invoke("kvtest", "save", ["a", "hi"], a)
      assert {:ok, "hi"} = Nexus.Toolkit.Js.invoke("kvtest", "get", ["a"], a)
      assert {:ok, ""} = Nexus.Toolkit.Js.invoke("kvtest", "get", ["a"], b)
    end
  end
end
