# VALIDATED: log ALL 15 Chunk-constructor params at entry (+ ALIVE control). CALL_NS showed the arg is
# defined at the call; this shows the arrival pattern at the constructor. A cutoff (D...DU...U) = real
# arg-loss; all D = the param-U was a clobber later or a mis-read. CKP fires once per Chunk construction.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")
driver = String.replace(driver,
  "this.orderedModules = orderedModules;",
  "console.log(\"CKP \"+[orderedModules,inputOptions,outputOptions,unsetOptions,pluginDriver,modulesById,chunkByModule,externalChunkByModule,facadeChunkByModule,includedNamespaces,manualChunkAlias,getPlaceholder,bundle,inputBase,snippets].map(function(x){return x===undefined?\"U\":\"D\"}).join(\"\")); this.orderedModules = orderedModules;")
combined = hp <> "\nhostCall(\"echo\", \"\"); console.log(\"ALIVE\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
out = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
report = fn ->
  s = out.()
  m = String.split(s,"\n") |> Enum.filter(fn l -> String.starts_with?(l,"ALIVE") or String.starts_with?(l,"CKP ") end) |> Enum.uniq()
  IO.puts("MARKERS: #{inspect(m)}")
  IO.puts("verdict: #{inspect(Regex.run(~r/BUNDLE_(OK|ERR)[^\n]*/, s))}")
end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE"); report.()
rescue e -> IO.puts("TRAP #{Exception.message(e)}"); report.()
catch :throw, {:wasm_exc,_,_} -> IO.puts("THROW"); report.()
end
