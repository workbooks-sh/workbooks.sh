defmodule Nexus.WashyRollupParserTest do
  @moduledoc """
  **Rollup's Rust wasm parser runs in Washy — the keystone for the literal `vite build` CLI (wb epic).**

  Modern Vite's production bundler is Rollup 4, whose parser is a Rust→wasm module shipped as
  `@rollup/wasm-node/bindings_wasm_bg.wasm` (557 KB, wasm-bindgen). The plan for running the real `vite`
  CLI is NOT a 50 MB Node-in-wasm — it's: run the Vite/Rollup **JavaScript** on our QuickJS, and route
  Rollup's native `parse()`/`parseAsync()` out to **this** wasm parser running as a SIBLING Washy module
  (host-mediated multi-module invocation — the emulation thesis). No wasm-in-QuickJS.

  This test proves the keystone: Washy loads the real wasm-bindgen Rust module, satisfies its 7
  `__wbindgen_*`/`__wbg_*` glue imports with tiny host shims (via the registrable `:washy_imports`
  table), drives `parse(retptr, ptr, len, allow_return, jsx)` over a persistent instance (malloc the
  source, call parse, read back the `{ptr,len}` AST buffer), and the result is **byte-for-byte
  identical** to what `@rollup/wasm-node` produces natively on Node (the golden fixture). That is real
  Rust, parsing real JS, correctly, on the BEAM.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @dir Path.join(__DIR__, "conformance/rollup")

  test "Rollup's Rust wasm parser runs in Washy; AST byte-identical to native @rollup/wasm-node" do
    wasm = Path.join(@dir, "rollup_parser.wasm")
    {:ok, mod} = Washy.decode(File.read!(wasm))

    # exactly 7 wasm-bindgen glue imports — provide minimal host shims. For a successful parse of valid
    # JS, the throw/error/stack paths never fire; the object-table ops get trivial stubs.
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

    code = File.read!(Path.join(@dir, "rollup_parse_input.js"))
    golden = File.read!(Path.join(@dir, "rollup_parser_golden.bin"))
    clen = byte_size(code)

    # a no-op setup (add_to_stack_pointer(0)) yields a live instance we re-enter for malloc + parse.
    {:ok, inst, _} = Washy.instance_start(mod, "__wbindgen_add_to_stack_pointer", [0])

    # passStringToWasm + parse, per the wasm-bindgen calling convention:
    {:ok, retptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [-16])
    {:ok, ptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_export2", [clen, 1])
    Washy.write_bytes(inst.mem, ptr, code)
    {:ok, _r, _o, inst} = Washy.instance_invoke(inst, "parse", [retptr, ptr, clen, 0, 0])

    r0 = Washy.read_bytes(inst.mem, retptr, 4) |> :binary.decode_unsigned(:little)
    r1 = Washy.read_bytes(inst.mem, retptr + 4, 4) |> :binary.decode_unsigned(:little)
    assert r0 > 0 and r1 > 0, "parse must return a non-empty AST buffer, got {#{r0}, #{r1}}"

    ast = Washy.read_bytes(inst.mem, r0, r1)
    assert ast == golden,
           "Washy's Rollup-parser AST (#{byte_size(ast)}B) must be byte-identical to native node's (#{byte_size(golden)}B)"
  end
end
