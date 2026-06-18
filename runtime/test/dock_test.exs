defmodule Workbooks.DockTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Dock, Literate, Wit}

  test "the registry holds the sandbox capabilities with their WIT interfaces" do
    assert "net" in Dock.capabilities()
    assert "net" in Dock.sandbox_capabilities()
    assert Dock.capability?("net")
    refute Dock.capability?("nope")

    assert Dock.interface_name("net") == "host-net"
    assert Dock.interface_wit("net") =~ "interface host-net {"
    assert Dock.interface_wit("kv") =~ "put: func(key: string, val: string);"
  end

  test "Wit projects exactly the interfaces the Dock registers — one source of truth" do
    src = "server :u, grant: [net: \"x\", kv: :c] do\n  def f(l), do: l\nend\n"
    pkg = Literate.parse(src) |> Wit.package("u")

    assert pkg =~ Dock.interface_wit("net")
    assert pkg =~ Dock.interface_wit("kv")
    assert pkg =~ "import #{Dock.interface_name("net")};"
    assert pkg =~ "import #{Dock.interface_name("kv")};"
  end
end
