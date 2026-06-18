defmodule Workbooks.DockTest do
  use ExUnit.Case, async: true
  alias Workbooks.{Dock, Literate, Wit}
  alias Workbooks.Instance.Imports

  test "wit/engine.wit is generated from the Dock registry and stays in sync" do
    world = Dock.engine_world()

    # the committed file is exactly what the registry generates (drift guard)
    assert File.read!("wit/engine.wit") == world

    # it covers every runtime capability the seam projects + session-info + run —
    # incl. llm-complete, which the old hand-written file was missing
    assert world =~ "import llm-complete: func(prompt: string) -> string;"
    assert world =~ "import session-info: func() -> string;"
    assert world =~ "export run: func(input: string) -> string;"

    for cap <- Dock.runtime_capabilities() do
      assert world =~ "import #{Dock.import_name(cap)}:"
    end
  end

  test "the registry is the union of sandbox caps and the live runtime seam caps" do
    assert "net" in Dock.sandbox_capabilities()
    assert "llm" in Dock.runtime_capabilities()
    refute "llm" in Dock.sandbox_capabilities()
    refute "net" in Dock.runtime_capabilities()
    assert Dock.runtime_cap_for("net") == "browse"
  end

  test "the registry accounts for every RustDock core-ABI import (Rust transport union)" do
    rust_surface =
      Workbooks.RustDock.imports(profile: :network) |> Map.fetch!("env") |> Map.keys()

    missing = rust_surface -- Dock.rust_abi_names()
    assert missing == [], "Dock registry is missing RustDock ABI names: #{inspect(missing)}"

    # and the ambient pair is exactly the always-present imports
    assert Enum.sort(Dock.rust_ambient()) == ~w(host_log host_now)
  end

  test "the registry's runtime import names match the LIVE Instance Dock seam (faithful projection)" do
    for cap <- Dock.runtime_capabilities() do
      live =
        Imports.for_caps([cap], nil, %{}, [])
        |> Map.keys()
        |> Enum.reject(&(&1 == "session-info"))

      assert live == [Dock.import_name(cap)],
             "cap #{cap}: registry says #{Dock.import_name(cap)}, seam projects #{inspect(live)}"
    end
  end

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
