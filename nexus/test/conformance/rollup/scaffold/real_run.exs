# Run the UNMODIFIED real rollup_bundle.cjs on the Porffor->Washy ASM (transpile) lane — the authoritative
# artifact, not the scaffold approximation. Assembly: bridge header (host bridge + node-global var decls) +
# the real node shims (compilers/js/node/*.js) + shim_prelude.js (node-surface gaps) + node-global binds +
# the real bundle (self-driving: prints BUNDLE_OK[<code>]). Compares the emitted bundle to the 66-byte golden.
import Bitwise
dir = __DIR__
root = Nexus.Compilers.Shared.default_root()
# host_prelude provides the proven byte-ABI `hostCall`; strip its parser-specialized `const __host` (our
# header defines the {ok,b64}/{h} __host the real bundle needs).
hp = Nexus.Compilers.Js.Porffor.host_prelude(root) |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
header = File.read!(Path.join(dir, "real_bridge.js"))
shims =
  Path.wildcard(Path.join([root, "js", "node", "*.js"]))
  |> Enum.sort()
  # 09_host.js defines __host/__host_async over the 2-arg STRING __host_call ABI, which conflicts with the
  # Porffor lane's 6-arg POINTER __host_call import — our header provides the byte-ABI __host instead.
  |> Enum.reject(&String.contains?(&1, "09_host"))
  |> Enum.map(&File.read!/1)
  |> Enum.join("\n")
shim_prelude = File.read!(Path.join([dir, "..", "shim_prelude.js"]))
# Porffor can't resolve a BARE identifier to a `globalThis.X` binding, so shim_prelude's internal bare
# `__addModule(...)` calls throw ReferenceError. Making the definition a module-LOCAL `var` (instead of a
# globalThis-stored boxed closure) lets the bare calls resolve to a directly-callable funcref — a member
# call `globalThis.__addModule(...)` on a boxed/capturing closure misdispatched ("undefined is not a fn").
shim_prelude = String.replace(shim_prelude, "globalThis.__addModule = function", "var __addModule = function")
bundle = File.read!(Path.join([dir, "..", "rollup_bundle.cjs"]))
golden = File.read!(Path.join([dir, "..", "rollup_bundle_golden.js"]))

binds = """
require = globalThis.require; module = globalThis.module; exports = globalThis.exports;
process = globalThis.process; Buffer = globalThis.Buffer; global = globalThis;
setTimeout = globalThis.setTimeout; clearTimeout = globalThis.clearTimeout;
setInterval = globalThis.setInterval; clearInterval = globalThis.clearInterval;
queueMicrotask = globalThis.queueMicrotask || function(f){ Promise.resolve().then(f); };
btoa = function(s){ return Buffer.from(String(s), 'binary').toString('base64'); };
atob = function(s){ return Buffer.from(String(s), 'base64').toString('binary'); };
"""

combined =
  hp <> "\n" <> header <> "\nhostCall(\"echo\", \"\");\n" <> shims <> "\n" <> shim_prelude <> "\n" <>
    binds <> "\n" <> bundle

# Porffor RESERVES the exact identifier `__host` — declaring `var __host` silently DROPS the `__host_call`
# import (proven by decode: imports lose the `e` entry), so the host bridge becomes undefined → t=38. Rename
# the `__host` identifier everywhere to `__nhost` (the host-bridge function the bundle/shims call). `\b__host\b`
# leaves `__host_call` (the import) and `hostCall` untouched.
combined = Regex.replace(~r/\b__host\b/, combined, "__nhost")

IO.puts("ASSEMBLED #{byte_size(combined)} bytes")
case Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"]) do
  {:ok, wasm} ->
    IO.puts("COMPILED wasm #{byte_size(wasm)}b")
    {:ok, mod} = Nexus.Washy.decode(wasm)
    Process.put(:porffor_out, [])
    emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
    Process.put(:washy_imports, %{
      "a" => fn [v] -> emit.(to_string(v)); nil end,
      "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
      "c" => fn [] -> 0.0 end, "d" => fn [] -> 0.0 end,
      "e" => &Nexus.Compilers.Js.PorfforHost.host_call/1
    })
    full = fn -> Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary() end
    report = fn ->
      s = full.()
      v = Regex.run(~r/BUNDLE_(OK|ERR)[^\n]*/, s) |> case do nil -> "NONE"; [m | _] -> m end
      IO.puts("verdict=#{String.slice(v, 0, 200)}")
      case String.split(s, "BUNDLE_OK[", parts: 2) do
        [_, rest] ->
          code = rest |> String.trim_trailing("\n") |> String.replace_suffix("]", "")
          IO.puts(if code == golden, do: "*** BYTE-MATCH GOLDEN ***", else: "DIFF len got=#{byte_size(code)} want=#{byte_size(golden)}")
        _ -> IO.puts("tail=" <> String.slice(s, max(byte_size(s) - 600, 0), 600))
      end
    end
    fuel = String.to_integer(System.get_env("FUEL") || "2000000000")
    try do
      Nexus.Washy.call_io(mod, "m", [], fuel: fuel, transpile: true, max_pages: String.to_integer(System.get_env("MAX_PAGES") || "16384"))
      IO.puts("DONE"); report.()
    rescue e -> IO.puts("TRAP #{Exception.message(e)}"); report.()
    catch :throw, {:wasm_exc, _, [ptr, t]} ->
      msg = try do
        p = trunc(ptr); mem = Process.get(:washy_mem)
        <<mp::little-32>> = Nexus.Washy.read_bytes(mem, p, 4)
        <<len::little-32>> = Nexus.Washy.read_bytes(mem, mp, 4)
        Nexus.Washy.read_bytes(mem, mp + 4, min(max(len, 0), 200))
      rescue _ -> "?" end
      IO.puts("THROW t=#{t} MSG=[#{msg}]"); report.()
    end
  e -> IO.puts("COMPILE-FAIL #{inspect(e)}")
end
