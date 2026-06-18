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
      |> WorkCore.Literate.parse()
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
      |> WorkCore.Literate.parse()
      |> Enum.find(&(&1.type == :code))

    %{world: world, imports: imports, exports: exports} = Nexus.Compile.rust_world(node)
    assert Enum.map(imports, &elem(&1, 0)) == ["add"]
    assert Enum.map(exports, &elem(&1, 0)) == ["run"]
    assert world =~ "import add: func(a: s32, b: s32) -> s32;"
    assert world =~ "export run: func() -> s32;"
  end

  # The single WIT generator: every lane (rust/zig/c) routes its world through
  # WorkCore.Wit.world_from_sigs, and each generated world is valid WIT. Fast (no toolchain) —
  # guards the de-dup that folded the per-lane hand-rolled builders into one home.
  test "every lane's generated WIT world routes through WorkCore.Wit and validates" do
    rust =
      ~s|rust :calc do\n  extern "C" { fn add(a: i32, b: i32) -> i32; }\n  #[no_mangle]\n  pub extern "C" fn compute() -> i32 { unsafe { add(20, 22) } }\nend\n|
      |> WorkCore.Literate.parse()
      |> Enum.find(&(&1.type == :code))

    %{world: rworld} = Nexus.Compile.rust_world(rust)
    assert rworld == "package work:calc;\n\nworld calc {\n  import add: func(a: s32, b: s32) -> s32;\n  export compute: func() -> s32;\n}\n"

    zworld = WorkCore.Wit.world_from_sigs("math", [], [{"quad", "func(x: s32) -> s32"}])
    assert zworld == "package work:math;\n\nworld math {\n  export quad: func(x: s32) -> s32;\n}\n"

    kw = WorkCore.Wit.world_from_sigs("record", [], [{WorkCore.Uid.wit("export"), "func() -> s32"}])
    assert kw =~ "world %record {"
    assert kw =~ "export %export:"

    if System.find_executable("wasm-tools") do
      assert WorkCore.Wit.validate(rworld) == :ok
      assert WorkCore.Wit.validate(zworld) == :ok
      assert WorkCore.Wit.validate(kw) == :ok
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
  test "a .work C unit compiles to a component and runs" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        "c :math do\n  int triple(int x) { return x * 3; }\nend\n"
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      {:ok, p} = Nexus.Sandbox.start(comp, [])
      assert {:ok, 42} = Nexus.Sandbox.call(p, "triple", [14])
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a C unit's STRING host cap is wired from the Dock signature and lifts" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|c :greeter do\n  extern void emit(const char* p, int n);\n  void greet(void) { emit("hi there", 8); }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      parent = self()
      {:ok, p} = Wasmex.Components.start_link(%{path: comp, imports: %{"emit" => {:fn, fn m -> send(parent, {:emit, m}); nil end}}})
      Wasmex.Components.call_function(p, "greet", [])
      assert_receive {:emit, "hi there"}, 3000
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "the clean GRANT-driven cap API works (no extern decls, injected wrapper)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|c :kv2, grant: [store, load, emit] do\n  void run(void) { store("c", 1, "porto", 5); nx_str v = load_s("c", 1); emit(v.ptr, v.len); }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      parent = self()
      imports = Map.merge(Nexus.Dock.impls(), %{"emit" => {:fn, fn m -> send(parent, {:emit, m}); nil end}})
      {:ok, p} = Wasmex.Components.start_link(%{path: comp, imports: imports})
      Wasmex.Components.call_function(p, "run", [])
      assert_receive {:emit, "porto"}, 3000
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a string-RETURNING cap works (kv store/load via the canonical-ABI return area)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|c :kv do\n  extern void store(const char* kp, int kl, const char* vp, int vl);\n  extern void load(const char* kp, int kl, void* ret);\n  extern void emit(const char* p, int n);\n  void run(void) { store("k", 1, "saved", 5); unsigned int r[2]; load("k", 1, r); emit((const char*)(unsigned long)r[0], (int)r[1]); }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      parent = self()
      imports = Map.merge(Nexus.Dock.impls(), %{"emit" => {:fn, fn m -> send(parent, {:emit, m}); nil end}})
      {:ok, p} = Wasmex.Components.start_link(%{path: comp, imports: imports})
      Wasmex.Components.call_function(p, "run", [])
      assert_receive {:emit, "saved"}, 3000
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a RUST unit's string host cap lifts (libstd stubs + selective rename)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|rust :greeter do\n  extern "C" { fn emit(p: *const u8, n: usize); }\n  #[no_mangle]\n  pub extern "C" fn greet() { let s = "hi rust"; unsafe { emit(s.as_ptr(), s.len()); } }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      parent = self()
      {:ok, p} = Wasmex.Components.start_link(%{path: comp, imports: %{"emit" => {:fn, fn m -> send(parent, {:emit, m}); nil end}}})
      Wasmex.Components.call_function(p, "greet", [])
      assert_receive {:emit, "hi rust"}, 3000
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a .work zig unit compiles to a component and runs" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        "zig :math do\n  export fn quad(x: i32) i32 { return x * 4; }\nend\n"
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      {:ok, p} = Nexus.Sandbox.start(comp, [])
      assert {:ok, 44} = Nexus.Sandbox.call(p, "quad", [11])
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a .work rust unit compiles to a component and runs" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|rust :doubler do\n  #[no_mangle]\n  pub extern "C" fn dbl(x: i32) -> i32 { x * 2 }\nend\n|
        |> WorkCore.Literate.parse()
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
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|rust :calc do\n  extern "C" { fn add(a: i32, b: i32) -> i32; }\n  #[no_mangle]\n  pub extern "C" fn compute() -> i32 { unsafe { add(20, 22) } }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      {:ok, pid} = Wasmex.Components.start_link(%{path: comp, imports: %{"add" => {:fn, fn a, b -> a + b end}}})
      assert {:ok, 42} = Wasmex.Components.call_function(pid, "compute", [])
    else
      :ok
    end
  end

  @tag :compiler
  @tag timeout: 240_000
  test "a unit's host import is supplied by the Dock automatically (turnkey cap)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasm-tools") do
      node =
        ~s|rust :clock do\n  extern "C" { fn now() -> i64; }\n  #[no_mangle]\n  pub extern "C" fn stamp() -> i64 { unsafe { now() } }\nend\n|
        |> WorkCore.Literate.parse()
        |> Enum.find(&(&1.type == :code))

      assert {:wasm, {:ok, comp}} = Nexus.Compile.unit(node)
      # Sandbox supplies `now` from the Dock — no manual import map.
      {:ok, p} = Nexus.Sandbox.start(comp, [])
      assert {:ok, t} = Nexus.Sandbox.call(p, "stamp", [])
      assert t > 1_700_000_000
    else
      :ok
    end
  end
end
