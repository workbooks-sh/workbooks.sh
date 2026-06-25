defmodule Nexus.WashyRollupParserAsmTest do
  @moduledoc """
  **The Rollup Rust wasm parser runs on Washy's ASM/transpiler lane, byte-identical to the interpreter.**

  `washy_rollup_parser_test.exs` proves the INTERPRETER (the correctness oracle) parses real JS byte-for-byte
  like native node. This test proves the **production lane**: the same parser, JIT-compiled function-by-function
  to BEAM assembly (`transpile: true, tier_threshold: 1`), produces a **byte-identical AST** to the interpreter
  across a spread of JS inputs (floats, classes, template literals, arrow fns, loops). The interp lane is the
  oracle; asm ≡ interp is the contract the transpiler must hold (it's what ships).

  This locks in two fixes (wb-7jwh):
    * the ModulePool generation-token race on the `:washy_jit` hot dispatch (stale slot → wrong function), and
    * the interp `call` pushing a result by `result == nil` rather than static arity — the asm void tail
      returns `0` (not nil), so calling an asm void fn from the interp leaked a phantom `0` (e.g. the f64
      number-parser returned `0` instead of `1.0` for `var x = 1.0;`).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @dir Path.join(__DIR__, "conformance/rollup")

  @inputs [
    "var x = 1.0;",
    "const y = 2 + 3 * 4; export { y };",
    "function f(a, b) { return a + b; } f(1, 2.5);",
    "let arr = [1, 2, 3].map(x => x * 1.5); console.log(arr);",
    "class A { constructor() { this.v = 3.14159; } get() { return this.v; } }",
    "const s = `hello ${1.5e3} world`; if (s.length > 0) { for (let i=0;i<10;i++){} }"
  ]

  # Run the parser over `code`, either interpreted or fully transpiled to the asm lane, returning the raw
  # AST buffer. Runs in a fresh task so the per-process `:washy_jit` dict + module pool state don't leak.
  defp parse(code, lane) do
    Task.async(fn ->
      {:ok, mod} = Washy.decode(File.read!(Path.join(@dir, "rollup_parser.wasm")))
      # Stamp a stable module id — the JIT's persistent cache (`cached_one`) keys on it and is DISABLED for a
      # nil id, which the production runtime never has (it loads via `decode_cached`, stamping the content
      # hash). With a stable id the transpiler builds a consistent, interoperable set of native functions.
      mod = %{mod | id: :rollup_parser_asm_test}

      rs = fn ptr, len -> Washy.read_bytes(Process.get(:washy_mem), ptr, len) end

      imports =
        mod.imports
        |> Enum.map(fn {_m, n, _t} -> n end)
        |> Map.new(fn n ->
          fun =
            cond do
              String.contains?(n, "throw") -> fn [p, l] -> raise("guest __wbindgen_throw: " <> rs.(p, l)) end
              String.contains?(n, "length") -> fn [_a] -> 0 end
              String.contains?(n, "new_") -> fn [] -> 1 end
              String.contains?(n, "prototypesetcall") -> fn [_a, _b, _c] -> nil end
              true -> fn _ -> nil end
            end

          {n, fun}
        end)

      Process.put(:washy_imports, imports)

      opts =
        case lane do
          :interp -> []
          :asm -> [transpile: true, tier_threshold: 1, tier_async: false]
        end

      clen = byte_size(code)
      {:ok, inst, _} = Washy.instance_start(mod, "__wbindgen_add_to_stack_pointer", [0], opts)
      {:ok, retptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [-16])
      {:ok, ptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_export2", [clen, 1])
      Washy.write_bytes(inst.mem, ptr, code)
      {:ok, _r, _o, inst} = Washy.instance_invoke(inst, "parse", [retptr, ptr, clen, 0, 0])

      r0 = Washy.read_bytes(inst.mem, retptr, 4) |> :binary.decode_unsigned(:little)
      r1 = Washy.read_bytes(inst.mem, retptr + 4, 4) |> :binary.decode_unsigned(:little)
      Washy.read_bytes(inst.mem, r0, r1)
    end)
    |> Task.await(120_000)
  end

  @tag timeout: 300_000
  test "ASM/transpiler lane parses byte-identical to the interpreter across varied JS" do
    for code <- @inputs do
      interp = parse(code, :interp)
      asm = parse(code, :asm)

      assert byte_size(interp) > 0, "interp parse must yield a non-empty AST for: #{code}"

      assert asm == interp,
             "asm lane must be byte-identical to interp for #{inspect(code)} " <>
               "(interp #{byte_size(interp)}B, asm #{byte_size(asm)}B)"
    end
  end
end
