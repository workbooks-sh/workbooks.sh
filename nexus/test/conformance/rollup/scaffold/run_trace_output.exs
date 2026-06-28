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
# instrument generateChunks: is outputOptions / graph / modulesById / includedModules the undefined one?
driver = String.replace(driver,
  "const includedModules = getIncludedModules(this.graph.modulesById);",
  "const includedModules = getIncludedModules(this.graph.modulesById); console.log(\"CHUNKTRACE oo=\"+(typeof this.outputOptions)+\" graph=\"+(typeof this.graph)+\" mbi=\"+(this.graph===undefined?\"NA\":typeof this.graph.modulesById)+\" incl=\"+(includedModules===undefined?\"U\":includedModules.length));")
# THE PUSH: does getOptimizedChunks return chunks, does .map work, does push(...spread) add them?
driver = String.replace(driver,
  "      chunkDefinitions.push(...getOptimizedChunks(chunks, minChunkSize, sideEffectAtoms, sizeByAtom, log).map(({ modules }) => ({\n        alias: null,\n        modules\n      })));",
  "      var __goc = getOptimizedChunks(chunks, minChunkSize, sideEffectAtoms, sizeByAtom, log); var __mapped = __goc.map(({ modules }) => ({ alias: null, modules })); console.log(\"PUSH goc=\"+__goc.length+\" mapped=\"+__mapped.length+\" before=\"+chunkDefinitions.length); chunkDefinitions.push(...__mapped); console.log(\"PUSH after=\"+chunkDefinitions.length);")
# getPartitionedChunks: the chunk sizes + small/big split (is minChunkSize wrong, or are sizes 0?)
driver = String.replace(driver,
  "      if (smallChunks.length === 0) {",
  "      console.log(\"GPC mcs2=\"+minChunkSize+\" small=\"+smallChunks.length+\" big=\"+bigChunks.length+\" sizes=\"+chunks.map(c=>c.size).join(\",\")); if (smallChunks.length === 0) {")
# getOptimizedChunks: small/big sizes AFTER mergeChunks (does merge empty them?)
driver = String.replace(driver,
  "      return [...chunkPartition.small, ...chunkPartition.big];",
  "      console.log(\"GOC small=\"+chunkPartition.small.size+\" big=\"+chunkPartition.big.size); return [...chunkPartition.small, ...chunkPartition.big];")
# INSIDE getChunkAssignments: which level drops the module? color → atoms → chunks → optimized.
driver = String.replace(driver,
  "      return chunkDefinitions;",
  "      console.log(\"GCA depEnt=\"+(dependentEntriesByModule===undefined?\"U\":dependentEntriesByModule.size)+\" atoms=\"+(chunkAtoms===undefined?\"U\":chunkAtoms.length)+\" chunks=\"+(chunks===undefined?\"U\":chunks.length)+\" mcs=\"+minChunkSize+\" defs=\"+chunkDefinitions.length); return chunkDefinitions;")
# after the chunk-assignment: how many chunks, how many entryModules, which branch?
driver = String.replace(driver,
  "const chunks = new Array(executableModule.length);",
  "console.log(\"CHUNK2 exec=\"+executableModule.length+\" entry=\"+(this.graph.entryModules===undefined?\"U\":this.graph.entryModules.length)+\" idi=\"+inlineDynamicImports+\" pm=\"+preserveModules); const chunks = new Array(executableModule.length);")
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
