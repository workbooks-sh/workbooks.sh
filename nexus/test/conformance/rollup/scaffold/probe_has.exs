# Name the undefined `.has` receiver WITHOUT instrumentation: compile with --namedReceiver, which enriches
# codegen's "Cannot read property X of undefined" throw with the receiver expression ([recv: ...]). The
# bundle's .catch prints BUNDLE_ERR <message>, so the verdict line names the undefined Set/Map. One run.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")
combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536", "--namedReceiver"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
out = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
report = fn ->
  s = out.()
  v = Regex.run(~r/BUNDLE_(OK|ERR)[^\n]*/, s)
  IO.puts("VERDICT: #{inspect(v)}")
  IO.puts("tail=[#{String.slice(s, max(byte_size(s)-300,0), 300)}]")
end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE"); report.()
rescue e -> IO.puts("TRAP #{Exception.message(e)}"); report.()
catch :throw, {:wasm_exc,_,_} -> IO.puts("THROW"); report.()
end
