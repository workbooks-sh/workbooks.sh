# Diagnostic: find which `X.code` read trips "Cannot read property 'code' of undefined" in the rollup build
# phase. Instruments the suspect receivers to log when undefined (right before the throwing read), then runs
# the proven scaffold via call_io (which keeps :tl_mem on a throw). Durable here, not /tmp.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")

# instrument the most-likely receivers (post-parse build phase). `(R===undefined&&console.log("UNDEF R"),R).code`
for r <- ["this.info", "source", "sourceDescription", "this.scope.context", "file", "cachedModule", "result",
          "emitPrebuiltChunk", "prebuiltChunk", "outputFile", "filter"] do
  driver = String.replace(driver, r <> ".code", "(" <> r <> "===undefined&&console.log(\"UNDEF:" <> r <> "\")," <> r <> ").code")
end

# the throw is likely a DESTRUCTURE of an undefined RHS: `const { code, … } = RHS`. Guard the two RHS objects.
for rhs <- ["this.scope.context", "transformedChunk"] do
  driver = String.replace(driver, "} = " <> rhs <> ";", "} = (" <> rhs <> "===undefined&&console.log(\"UNDEF-destructure:" <> rhs <> "\")," <> rhs <> ");")
end

combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"])
{:ok, mod} = TinyLasers.Wasm.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:tl_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
full = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
tailf = fn -> s = full.(); String.slice(s, max(byte_size(s)-600,0), 600) end
try do
  TinyLasers.Wasm.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE tail=[#{tailf.()}]")
rescue e -> IO.puts("TRAP #{Exception.message(e)} tail=[#{tailf.()}]")
catch
  :throw, {:wasm_exc,_,[ptr,t]} ->
    p=trunc(ptr); mem=Process.get(:tl_mem); <<mp::little-32>> = TinyLasers.Wasm.read_bytes(mem,p,4); <<len::little-32>> = TinyLasers.Wasm.read_bytes(mem,mp,4)
    IO.puts("THROW t=#{t} MSG=[#{TinyLasers.Wasm.read_bytes(mem,mp+4,min(max(len,0),120))}] tail=[#{tailf.()}]")
end
