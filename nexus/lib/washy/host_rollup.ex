defmodule Nexus.Washy.HostRollup do
  @moduledoc """
  **The QuickJS↔Rollup-parser bridge — the keystone of running the literal `vite build` CLI in Washy.**

  Modern Vite's production bundler is Rollup 4, whose parser + hasher are a Rust→wasm module
  (`@rollup/wasm-node/bindings_wasm_bg.wasm`). Rollup's *JavaScript* runs on our QuickJS; its native
  `parse()`/`xxhash*()` calls are routed here via the generic `__host(name,args)` seam (see
  `Nexus.Washy.HostIO`) — and we run the Rust parser as a SIBLING Washy module, returning the result to
  QuickJS. Two wasm modules cooperating through the host: the emulation thesis, no wasm-in-QuickJS.

  The parser instance is created lazily on first call and cached in the process dict
  (`:washy_rollup_parser`); `instance_invoke` snapshots/restores the caller's (QuickJS) run context, so
  invoking the parser mid-QuickJS-run is safe. The 7 wasm-bindgen glue imports are satisfied with tiny
  host shims via the registrable `:washy_imports` table (proven byte-identical to native in
  `washy_rollup_parser_test.exs`).
  """
  import Bitwise
  alias Nexus.Washy

  # The parser wasm asset. (Currently the vendored conformance fixture; promote to a runtime asset dir
  # when this graduates from probe to shipped capability.)
  @parser_wasm Path.join(:code.priv_dir(:nexus) |> to_string(), "../test/conformance/rollup/rollup_parser.wasm")

  @doc "sync `__host('rollup_parse', [code, allowReturn, jsx])` → %{ok, b64: base64(AST buffer)}."
  def call("rollup_parse", [code | rest]) do
    allow = Enum.at(rest, 0, false)
    jsx = Enum.at(rest, 1, false)
    inst = ensure_parser()
    {buf, inst} = do_parse(inst, to_string(code), bool(allow), bool(jsx))
    Process.put(:washy_rollup_parser, inst)
    %{"ok" => true, "b64" => Base.encode64(buf)}
  end

  # Rollup hashes chunk contents with xxhash for `[hash]` filenames. A faithful, deterministic,
  # collision-resistant hash is all Rollup needs — we use erlang's hasher and render it in the requested
  # alphabet. (The wasm module also exports xxhash*, but a host-side hash is simpler and equally valid.)
  def call("rollup_xxhash", [b64, kind]) do
    bytes = Base.decode64!(b64)
    h = :erlang.crc32(bytes) ||| (:erlang.phash2(bytes, 0xFFFFFFFF) <<< 32)
    %{"h" => render_hash(h, kind)}
  end

  defp bool(v), do: v == true or v == 1

  defp render_hash(h, "b16"), do: Integer.to_string(h, 16) |> String.downcase() |> String.pad_leading(16, "0") |> binary_part(0, 16)
  defp render_hash(h, "b36"), do: Integer.to_string(h, 36) |> String.downcase() |> String.pad_leading(12, "0") |> binary_part(0, 12)

  defp render_hash(h, _b64url) do
    <<h::64>> |> Base.url_encode64(padding: false) |> binary_part(0, 11)
  end

  # ── parser instance lifecycle ────────────────────────────────────────────────────────────────────
  defp ensure_parser do
    case Process.get(:washy_rollup_parser) do
      nil ->
        {:ok, mod} = Washy.decode(File.read!(@parser_wasm))
        Process.put(:washy_imports, Map.merge(Process.get(:washy_imports, %{}), parser_shims(mod)))
        {:ok, inst, _} = Washy.instance_start(mod, "__wbindgen_add_to_stack_pointer", [0])
        inst

      inst ->
        inst
    end
  end

  # the 7 wasm-bindgen glue imports — minimal host shims (success path never hits throw/error/stack).
  defp parser_shims(mod) do
    rs = fn ptr, len -> Washy.read_bytes(Process.get(:washy_mem), ptr, len) end

    mod.imports
    |> Enum.map(fn {_m, n, _t} -> n end)
    |> Map.new(fn n ->
      fun =
        cond do
          String.contains?(n, "throw") -> fn [p, l] -> raise("rollup parser __wbindgen_throw: " <> rs.(p, l)) end
          String.contains?(n, "length") -> fn [_a] -> 0 end
          String.contains?(n, "new_") -> fn [] -> 1 end
          String.contains?(n, "prototypesetcall") -> fn [_a, _b, _c] -> nil end
          true -> fn _ -> nil end
        end

      {n, fun}
    end)
  end

  # the wasm-bindgen parse calling convention: reserve 16, malloc+copy the source, call parse, read
  # back {ptr,len} = the flat AST buffer. Returns {buffer, threaded_instance}.
  defp do_parse(inst, code, allow, jsx) do
    clen = byte_size(code)
    {:ok, retptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [-16])
    {:ok, ptr, _, inst} = Washy.instance_invoke(inst, "__wbindgen_export2", [clen, 1])
    Washy.write_bytes(inst.mem, ptr, code)
    a = if(allow, do: 1, else: 0)
    j = if(jsx, do: 1, else: 0)
    {:ok, _, _, inst} = Washy.instance_invoke(inst, "parse", [retptr, ptr, clen, a, j])

    r0 = Washy.read_bytes(inst.mem, retptr, 4) |> :binary.decode_unsigned(:little)
    r1 = Washy.read_bytes(inst.mem, retptr + 4, 4) |> :binary.decode_unsigned(:little)
    buf = Washy.read_bytes(inst.mem, r0, r1)
    {:ok, _, _, inst} = Washy.instance_invoke(inst, "__wbindgen_add_to_stack_pointer", [16])
    {buf, inst}
  end
end
