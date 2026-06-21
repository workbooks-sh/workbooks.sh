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

  defp run_wasm(wasm, stdin) do
    sin = Path.join(System.tmp_dir!(), "lanein_#{System.unique_integer([:positive])}")
    File.write!(sin, stdin)
    {out, code} = System.cmd("sh", ["-c", "wasmtime run #{wasm} < #{sin}"], stderr_to_stdout: true)
    File.rm(sin)
    {out, code}
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
    # (cached/2 wraps the lane result, hence the {:wasm, {:error, ...}} envelope.)
    bogus = %{n | lang: "cobol"}
    assert {:wasm, {:error, {:sandbox_unknown_lang, "cobol", "encode"}}} = Nexus.Compile.unit(bogus)
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

      assert {:wasm, {:ok, wasm}} = Nexus.Compile.unit(n)
      assert {out, 0} = run_wasm(wasm, "hello\n")
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

      assert {:wasm, {:ok, wasm}} = Nexus.Compile.unit(n)
      assert {out, 0} = run_wasm(wasm, "hi\n")
      assert out =~ "HI"
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
      assert {:wasm, {:ok, wasm}} = Nexus.Compile.unit(n)
      assert {out, 0} = run_wasm(wasm, "sandboxed\n")
      assert out =~ "sandboxed"
    end
  end
end
