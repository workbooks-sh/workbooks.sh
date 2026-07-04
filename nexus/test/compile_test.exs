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

  # The single WIT generator: every lane (rust/zig/c) routes its world through
  # Nexus.Wit.world_from_sigs, and each generated world is valid WIT. Fast (no toolchain) —
  # guards the de-dup that folded the per-lane hand-rolled builders into one home.
  test "every lane's generated WIT world routes through Nexus.Wit and validates" do
    rust =
      ~s|rust :calc do\n  extern "C" { fn add(a: i32, b: i32) -> i32; }\n  #[no_mangle]\n  pub extern "C" fn compute() -> i32 { unsafe { add(20, 22) } }\nend\n|
      |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code))

    %{world: rworld} = Nexus.Compile.rust_world(rust)
    assert rworld == "package work:calc;\n\nworld calc {\n  import add: func(a: s32, b: s32) -> s32;\n  export compute: func() -> s32;\n}\n"

    zworld = Nexus.Wit.world_from_sigs("math", [], [{"quad", "func(x: s32) -> s32"}])
    assert zworld == "package work:math;\n\nworld math {\n  export quad: func(x: s32) -> s32;\n}\n"

    kw = Nexus.Wit.world_from_sigs("record", [], [{Nexus.Uid.wit("export"), "func() -> s32"}])
    assert kw =~ "world %record {"
    assert kw =~ "export %export:"

    if System.find_executable("wasm-tools") do
      assert Nexus.Wit.validate(rworld) == :ok
      assert Nexus.Wit.validate(zworld) == :ok
      assert Nexus.Wit.validate(kw) == :ok
    end
  end

  # The real proof: a .work rust unit → component → runs on wasmex. Needs the wasm toolchain
  # (mrustc/clang in compilers/) + wasm-tools; skips otherwise. Slow (real compile).
  test "workbook/1 brings up a folder — resources live, wasm units enumerated" do
    dir = Path.join(System.tmp_dir!(), "wbk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "lead.work"), "resource Lead do\n  name :text\n  revenue :int\nend\n")
    File.write!(Path.join(dir, "score.work"), "rust :scorer do\n  pub extern \"C\" fn score(x: i32) -> i32 { x }\nend\n")

    wb = Nexus.Compile.workbook(dir)
    assert [{"Lead", {:ok, _mod}}] = wb.resources
    assert wb.wasm_units == ["scorer"]

    File.rm_rf!(dir)
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a .work C unit compiles via the route-a {:core} lane and runs on TinyLasers.Wasm (no wasmex)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      node =
        "c :math do\n  int triple(int x) { return x * 3; }\nend\n"
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:core, {:ok, core, exports, _str}} = Nexus.Compile.unit(node)
      assert "triple" in exports
      {:ok, mod} = TinyLasers.Wasm.decode(File.read!(core))

      {:completed, {v, _out}} =
        TinyLasers.Gate.bounded(fn -> TinyLasers.Wasm.call_io(mod, "triple", [14], []) end,
          timeout: 60_000,
          max_heap_size: 268_435_456
        )

      assert v == 42
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a route-a C unit's grant caps + string RETURN work end-to-end through the {:core} lane" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      node =
        ~s|c :kv, grant: [store, load] do\n  nx_str run(void) { store("k", 1, "saved", 5); return load("k", 1); }\nend\n|
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:core, {:ok, core, exports, str_exports}} = Nexus.Compile.unit(node)
      assert "run" in exports and "run" in str_exports
      {:ok, mod} = TinyLasers.Wasm.decode(File.read!(core))

      Process.put(:dock_tenant, "compile-test-kv-lane")
      Process.put(:dock_caps, ["kv"])
      # store("saved") then RETURN load("k") as a string — grant caps + §5b string return via the lane
      assert {:ok, "saved"} = Nexus.Wasm.Sandbox.run_str(mod, "run", [])
    else
      :ok
    end
  end

  # (route-a rust cap coverage lives in compile_core_test — store/load round-trip through HostDock; the
  # old wasmex-component rust cap test retired with the component model.)

  @tag :compiler
  @tag timeout: 240_000
  test "a .work zig unit compiles via the route-a {:core} lane and runs on TinyLasers.Wasm (no wasmex)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      node =
        "zig :math do\n  export fn quad(x: i32) i32 { return x * 4; }\nend\n"
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:core, {:ok, core, exports, _str}} = Nexus.Compile.unit(node)
      assert "quad" in exports
      {:ok, mod} = TinyLasers.Wasm.decode(File.read!(core))

      {:completed, {v, _out}} =
        TinyLasers.Gate.bounded(fn -> TinyLasers.Wasm.call_io(mod, "quad", [11], []) end,
          timeout: 60_000,
          max_heap_size: 268_435_456
        )

      assert v == 44
    else
      :ok
    end
  end

  # (the WIT-overlay/artifact_overlay drift test retired with the component model — no lang produces WIT
  # components anymore, all route-a core; artifact_overlay is dead code pending the Step 6 deletes.)

  @tag :compiler
  @tag timeout: 240_000
  test "a .work rust unit compiles via the route-a {:core} lane and runs on TinyLasers.Wasm (no wasmex)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      node =
        ~s|rust :doubler do\n  #[no_mangle]\n  pub extern "C" fn dbl(x: i32) -> i32 { x * 2 }\nend\n|
        |> Nexus.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:core, {:ok, core, exports, _str}} = Nexus.Compile.unit(node)
      assert "dbl" in exports
      {:ok, mod} = TinyLasers.Wasm.decode(File.read!(core))

      {:completed, {v, _out}} =
        TinyLasers.Gate.bounded(fn -> TinyLasers.Wasm.call_io(mod, "dbl", [42], []) end,
          timeout: 120_000,
          max_heap_size: 268_435_456
        )

      assert v == 84
    else
      :ok
    end
  end

  # (the wasmex host-import rust tests retired with the component model: arbitrary host imports aren't a
  # route-a concept — route (a) wires only Dock caps via host_call→HostDock; Dock-cap coverage for rust
  # lives in compile_core_test. Zero-arg number caps like `now` need rust wrapper codegen — a follow-up.)
end
