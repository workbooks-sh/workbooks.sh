defmodule Nexus.DockCapsTest do
  use ExUnit.Case, async: true

  test "the host-fn registry carries each cap with its WIT signature" do
    fns = Nexus.Dock.host_fns()
    for n <- ~w(now emit store load fetch complete), do: assert Map.has_key?(fns, n)
    assert Nexus.Dock.host_fn_wit("fetch") == "func(url: string) -> string"
    assert Nexus.Dock.host_fn_wit("complete") == "func(prompt: string) -> string"
    assert Nexus.Dock.host_fn_wit("emit") == "func(msg: string)"
  end

  test "returns_string? distinguishes string-returning caps from the rest" do
    assert Nexus.Dock.returns_string?("fetch")
    assert Nexus.Dock.returns_string?("load")
    refute Nexus.Dock.returns_string?("emit")
    refute Nexus.Dock.returns_string?("now")
    refute Nexus.Dock.returns_string?("nonexistent")
  end

  test "impls/0 exposes every cap as a wasmex import fn" do
    impls = Nexus.Dock.impls()
    for n <- ~w(now emit store load fetch), do: assert match?({:fn, _}, impls[n])
  end

  test "fetch is SSRF-brokered — loopback/private/non-http are blocked (return \"\")" do
    for url <- [
          "http://127.0.0.1:4000/x",
          "http://localhost/x",
          "http://10.0.0.5/x",
          "http://192.168.1.1/x",
          "http://169.254.169.254/latest/meta-data",
          "http://172.16.0.1/x",
          "file:///etc/passwd"
        ] do
      assert Nexus.Dock.fetch(url) == ""
    end
  end
end
