defmodule Nexus.CompileLanesTest do
  @moduledoc """
  The compile-lane routing: `client` is a render passthrough (not a wasm lane); `sandbox` routes to
  its inner language; the JS family (js/ts) compiles to a runnable command module. Compiler-backed
  cases are tagged `:compiler` and skip cleanly when the toolchain isn't present.
  """
  use ExUnit.Case, async: false

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  defp toolchain? do
    root = Nexus.Compilers.Shared.default_root()
    System.find_executable("wasmtime") && File.regular?(Path.join([root, "js", "harness.o"]))
  end


  test "client is a render passthrough, never an unbuilt-lane error" do
    n = unit("client :ui do\n  <h1>hello</h1>\nend\n")
    assert n.kind == "client"
    assert {:client, body} = Nexus.Compile.unit(n)
    assert body =~ "<h1>hello</h1>"
  end

  test "sandbox routes to its inner language (not treated as its own kind)" do
    n = unit("sandbox zig :encode do\n  pub fn encode(x: u32) u32 { return x; }\nend\n")
    assert n.kind == "sandbox"
    assert n.lang == "zig"
    # Prove the sandbox arm is wired without the slow zig compile: an unsupported inner lang takes
    # the only fast error path (:sandbox_unknown_lang), NOT the {:unbuilt_lane} misclassification.
    bogus = %{n | lang: "cobol"}
    assert {:error, {:sandbox_unknown_lang, "cobol", "encode"}} = Nexus.Compile.unit(bogus)
  end

  @tag :compiler
  test "js lane compiles a unit to a runnable command module" do
    if !toolchain?() do
      :ok
    else
      n = unit(~S|js :upper do
  const b = new Uint8Array(65536);
  const k = Javy.IO.readSync(0, b);
  console.log(new TextDecoder().decode(b.subarray(0,k)).trim().toUpperCase());
end|)

      # js is a COMMAND-module lane (stdin→stdout); run it through the unified run path
      assert {:command, {:ok, spec}} = Nexus.Compile.unit(n)
      assert {:ok, out} = Nexus.Sandbox.run_command(spec, "hello\n")
      assert out =~ "HELLO"
    end
  end

  @tag :compiler
  test "ts lane strips types, compiles, and runs" do
    if !toolchain?() do
      :ok
    else
      n = unit(~S|ts :greet do
  const up = (s: string): string => s.toUpperCase();
  const b = new Uint8Array(65536);
  const k = Javy.IO.readSync(0, b);
  console.log(up(new TextDecoder().decode(b.subarray(0,k)).trim()));
end|)

      assert {:command, {:ok, spec}} = Nexus.Compile.unit(n)
      assert {:ok, out} = Nexus.Sandbox.run_command(spec, "hi\n")
      assert out =~ "HI"
    end
  end

  @tag :compiler
  test "svelte unit transpiles to a client island (not a server command module)" do
    root = Nexus.Compilers.Shared.default_root()

    if !File.regular?(Path.join([root, "svelte", "vendor", "compiler.cjs"])) do
      :ok
    else
      n = unit("svelte :greeting do\n  <script>export let name = \"world\";</script>\n  <h1>Hi {name}</h1>\nend\n")
      assert n.kind == "svelte"
      assert {:client, js} = Nexus.Compile.unit(n)
      assert is_binary(js) and byte_size(js) > 0
    end
  end

  @tag :compiler
  test "python unit yields a runnable interpreter that executes the program" do
    root = Nexus.Compilers.Shared.default_root()
    interp = Path.join([root, "python", "pythonrun.wasm"])

    if !File.regular?(interp) || !System.find_executable("wasmtime") do
      :ok
    else
      # python compiles to a {:command, {:interp, …}} spec carrying the dedented source; the unified
      # run path mounts it + runs the interpreter (the source's indentation is dedented by compile.ex).
      n = unit("python :up do\n  import sys\n  print(sys.stdin.read().strip().upper())\nend\n")
      assert n.kind == "python"
      assert {:command, {:ok, {:interp, _interp, src} = spec}} = Nexus.Compile.unit(n)
      assert src == "import sys\nprint(sys.stdin.read().strip().upper())"
      assert {:ok, out} = Nexus.Sandbox.run_command(spec, "hi\n")
      assert out =~ "HI"
    end
  end

  @tag :compiler
  test "solid unit transpiles to a client island via StarlingMonkey" do
    root = Nexus.Compilers.Shared.default_root()
    bundle = Path.join([root, "solid", "vendor", "babel.js"])
    evalhost = Path.expand("priv/eval-host.wasm", File.cwd!())

    if !File.regular?(bundle) || !File.regular?(evalhost) do
      :ok
    else
      n = unit("solid :counter do\n  const App = () => { const [c,setC]=createSignal(0); return <button onClick={()=>setC(c()+1)}>n {c()}</button>; };\nend\n")
      assert n.kind == "solid"
      assert {:client, js} = Nexus.Compile.unit(n)
      # dom-expressions output — the proof the Solid transform actually ran
      assert js =~ "_$template" or js =~ "_tmpl$"
    end
  end

  @tag :compiler
  test "sandbox js :name compiles through the inner JS lane" do
    if !toolchain?() do
      :ok
    else
      n = unit(~S|sandbox js :echo do
  const b = new Uint8Array(65536);
  const k = Javy.IO.readSync(0, b);
  console.log(new TextDecoder().decode(b.subarray(0,k)).trim());
end|)

      assert n.kind == "sandbox" and n.lang == "js"
      # sandbox routes to the inner js lane → a command module
      assert {:command, {:ok, spec}} = Nexus.Compile.unit(n)
      assert {:ok, out} = Nexus.Sandbox.run_command(spec, "sandboxed\n")
      assert out =~ "sandboxed"
    end
  end
end
