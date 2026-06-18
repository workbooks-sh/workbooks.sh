defmodule Nexus.LangsTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Nexus.Langs.clear_registered() end)
    :ok
  end

  test "the built-in WebAssembly compiler languages are registered with their shapes" do
    assert Nexus.Langs.ids() == ["c", "rust", "zig"]
    assert Nexus.Langs.get("rust").id() == "rust"
    assert Nexus.Langs.supports?("c", :command) and Nexus.Langs.supports?("c", :component)
    assert Nexus.Langs.supports?("rust", :command)
    assert Nexus.Langs.supports?("zig", :component)
    refute Nexus.Langs.supports?("zig", :command)
    refute Nexus.Langs.supports?("nope", :command)
  end

  test "the catalog lists each language with its shapes + summary" do
    cat = Nexus.Langs.catalog()
    assert cat =~ "rust (command, component)"
    assert cat =~ "zig (component)"
  end

  test "compile guards unknown language + unsupported shape" do
    assert {:error, {:unknown_lang, "haskell"}} = Nexus.Langs.compile("haskell", "/tmp/x", :command)
    assert {:error, {:unsupported_shape, "zig", :command}} = Nexus.Langs.compile("zig", "/tmp/x", :command)
  end

  test "a custom language can be registered (the extension point)" do
    defmodule TestLang do
      @behaviour Nexus.Lang
      def id, do: "testlang"
      def summary, do: "a test wasm language"
      def shapes, do: [:command]
      def compile(_src, :command, _opts), do: {:ok, "/tmp/testlang.wasm"}
    end

    Nexus.Langs.register(TestLang)
    assert "testlang" in Nexus.Langs.ids()
    assert Nexus.Langs.supports?("testlang", :command)
    assert {:ok, "/tmp/testlang.wasm"} = Nexus.Langs.compile("testlang", "/tmp/x", :command)
  end
end
