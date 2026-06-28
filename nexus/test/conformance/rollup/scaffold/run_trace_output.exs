# Trace the rollup OUTPUT structure (resilient mode, so generate() completes): replace the BUNDLE_OK line
# with verbose logging of output.length / output[0] / output[0].code — to find WHERE the chunk pipeline
# drops to undefined (empty output? undefined chunk? undefined code?). No codegen change.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")
# verbose output trace at the BUNDLE_OK site
driver = String.replace(driver,
  "\"BUNDLE_OK[\" + output[0].code + \"]\"",
  "\"OUTTRACE len=\" + output.length + \" t0=\" + (typeof output[0]) + \" o0undef=\" + (output[0] === undefined) + \" codeT=\" + (output[0] === undefined ? \"NA\" : typeof output[0].code) + \" fileName=\" + (output[0] === undefined ? \"NA\" : output[0].fileName)")
combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536", "--undefResilient"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
out = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE out=[#{String.slice(out.(), max(byte_size(out.())-400,0), 400)}]")
rescue e -> IO.puts("TRAP #{Exception.message(e)} out=[#{String.slice(out.(),-300,300)}]")
catch :throw, {:wasm_exc,_,_} -> IO.puts("THROW out=[#{String.slice(out.(),-300,300)}]")
end
