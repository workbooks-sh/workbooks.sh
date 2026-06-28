import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")
combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, Nexus.Compilers.Shared.default_root(), flags: ["--pageSize=65536"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:washy_oob_debug, true)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
full = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
dump = fn -> s = full.(); n = byte_size(s); "tail=" <> String.slice(s, max(n-1500,0), 1500) <> " <<verdict>>" <> (Regex.run(~r/BUNDLE_(OK|ERR)[^\n]*/, s) |> case do nil -> "NONE"; [m|_] -> m end) end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE out=[#{dump.()}]")
rescue
  e -> IO.puts("TRAP #{Exception.message(e)} OUT=[#{dump.()}]")
catch
  :throw, {:wasm_exc,_,[ptr,t]} ->
    p=trunc(ptr); mem=Process.get(:washy_mem); <<mp::little-32>> = Nexus.Washy.read_bytes(mem,p,4); <<len::little-32>> = Nexus.Washy.read_bytes(mem,mp,4)
    IO.puts("THROW t=#{t} MSG=[#{Nexus.Washy.read_bytes(mem,mp+4,min(max(len,0),120))}] OUT=[#{dump.()}]")
end
