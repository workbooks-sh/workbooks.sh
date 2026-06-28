# Find the render-phase undefined `.has` receiver. Auto-extracts EVERY `X.has(` receiver from the driver and
# instruments each to log when undefined right before the throw. Non-resilient (real run). Durable, not /tmp.
import Bitwise
root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!(Path.join(__DIR__, "rollup_node.js"))
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")

receivers =
  Regex.scan(~r/([A-Za-z_][A-Za-z0-9_.]*)\.has\(/, driver)
  |> Enum.map(fn [_, r] -> r end)
  |> Enum.uniq()
  |> Enum.reject(&String.contains?(&1, "console"))
  |> Enum.reject(&String.contains?(&1, "."))  # simple identifiers only — dotted receivers risk breaking the wrap

driver =
  Enum.reduce(receivers, driver, fn r, acc ->
    String.replace(acc, r <> ".has(", "(" <> r <> "===undefined&&console.log(\"HAS_UNDEF:" <> r <> "\")," <> r <> ").has(")
  end)
IO.puts("[probe] instrumented #{length(receivers)} .has receivers")

combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
{:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(combined, root, flags: ["--pageSize=65536"])
{:ok, mod} = Nexus.Washy.decode(wasm)
Process.put(:porffor_out, [])
emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end
Process.put(:washy_imports, %{"a"=>fn [v]->emit.(to_string(v));nil end,"b"=>fn [v]->emit.(<<trunc(v)::utf8>>);nil end,"c"=>fn []->0.0 end,"d"=>fn []->0.0 end,"e"=>&Nexus.Compilers.Js.PorfforHost.host_call/1})
out = fn -> Process.get(:porffor_out,[]) |> Enum.reverse() |> IO.iodata_to_binary() end
report = fn ->
  s = out.()
  hits = String.split(s,"\n") |> Enum.filter(&String.starts_with?(&1,"HAS_UNDEF:")) |> Enum.uniq()
  IO.puts("HAS-UNDEF-HITS: #{inspect(hits)}")
  IO.puts("tail=[#{String.slice(s, max(byte_size(s)-300,0), 300)}]")
end
try do
  Nexus.Washy.call_io(mod, "m", [], fuel: 400_000_000, transpile: true, max_pages: 16384)
  IO.puts("DONE"); report.()
rescue e -> IO.puts("TRAP #{Exception.message(e)}"); report.()
catch :throw, {:wasm_exc,_,_} -> IO.puts("THROW"); report.()
end
