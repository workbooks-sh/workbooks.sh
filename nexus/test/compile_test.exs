defmodule Nexus.CompileTest do
  use ExUnit.Case, async: false

  # Fast + pure: the typed WIT world derived from a rust unit's signatures (no toolchain).
  test "rust_world derives a typed WIT world from pub fn signatures" do
    node =
      """
      rust :forecast do
        #[no_mangle]
        pub extern "C" fn forecast(x: i32) -> i32 { x }
        #[no_mangle]
        pub extern "C" fn blend(a: f64, b: f64) -> f64 { a }
      end
      """
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))

    %{world: world, name: name, exports: exports} = Nexus.Compile.rust_world(node)
    assert name == "forecast"
    assert Enum.map(exports, &elem(&1, 0)) == ["forecast", "blend"]
    assert world =~ "export forecast: func(x: s32) -> s32;"
    assert world =~ "export blend: func(a: f64, b: f64) -> f64;"
  end

  test "rust_world derives host imports from extern \"C\" declarations" do
    node =
      """
      rust :calc do
        extern "C" { fn add(a: i32, b: i32) -> i32; }
        #[no_mangle]
        pub extern "C" fn run() -> i32 { unsafe { add(1, 2) } }
      end
      """
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))

    %{world: world, imports: imports, exports: exports} = Nexus.Compile.rust_world(node)
    assert Enum.map(imports, &elem(&1, 0)) == ["add"]
    assert Enum.map(exports, &elem(&1, 0)) == ["run"]
    assert world =~ "import add: func(a: s32, b: s32) -> s32;"
    assert world =~ "export run: func() -> s32;"
  end

  # The real proof: a .work rust unit → component → runs on wasmex. Needs the wasm toolchain
  # (mrustc/clang in ../runtime/compilers) + wasm-tools; skips otherwise. Slow (real compile).
  @tag :compiler
  @tag timeout: 240_000
  test "a .work rust unit compiles to a component and runs" do
    if File.dir?("../runtime/compilers") && System.find_executable("wasm-tools") do
      node =
        ~s|rust :doubler do\n  #[no_mangle]\n  pub extern "C" fn dbl(x: i32) -> i32 { x * 2 }\nend\n|
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      {:ok, p} = Nexus.Sandbox.start(comp, [])
      assert {:ok, 84} = Nexus.Sandbox.call(p, "dbl", [42])
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a .work rust unit with a host IMPORT compiles, and the host supplies it" do
    if File.dir?("../runtime/compilers") && System.find_executable("wasm-tools") do
      node =
        ~s|rust :calc do\n  extern "C" { fn add(a: i32, b: i32) -> i32; }\n  #[no_mangle]\n  pub extern "C" fn compute() -> i32 { unsafe { add(20, 22) } }\nend\n|
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      {:ok, pid} = Wasmex.Components.start_link(%{path: comp, imports: %{"add" => {:fn, fn a, b -> a + b end}}})
      assert {:ok, 42} = Wasmex.Components.call_function(pid, "compute", [])
    else
      :ok
    end
  end
end
