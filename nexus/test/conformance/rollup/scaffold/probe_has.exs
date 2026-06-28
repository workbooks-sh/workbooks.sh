# Find which `X.has(` receiver is undefined in the chunk-render phase ("Cannot read property 'has' of
# undefined"). Instrument the render-phase Set/Map receivers to log when undefined right before the throw.
# Non-resilient (real run) so the throw lands at the real undefined one. Durable here, not /tmp.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")

for r <- ["exportNamesByVariable", "includedNamespaces", "this.includedNamespaces", "accessedGlobals",
          "usedHelpers", "RESERVED_NAMES", "WELL_KNOWN_SYMBOLS", "moduleExportNamesByVariable",
          "exportsByName", "usedNames", "this.variables", "trackedEntities", "this.deoptimizedFields"] do
  driver = String.replace(driver, r <> ".has(", "(" <> r <> "===undefined&&console.log(\"HAS_UNDEF:" <> r <> "\")," <> r <> ").has(")
end

combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
out = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE tail=[#{String.slice(out.(), max(byte_size(out.())-500,0), 500)}]")
rescue e -> IO.puts("TRAP #{Exception.message(e)}")
catch :throw, {:wasm_exc,_,_} -> IO.puts("THROW tail=[#{String.slice(out.(),-500,500)}]")
end
