root = Nexus.Compilers.Shared.default_root()
hp = Nexus.Compilers.Js.Porffor.host_prelude(root)
hp = hp |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "const __host ")) |> Enum.join("\n")
driver = File.read!("/tmp/rollup_node.js")
driver = String.replace(driver, ~r/var __hostCall = \(op, req\) => \{.*?\n\};\n/s, "")
driver = String.replace(driver, "__hostCall(", "hostCall(")
combined = hp <> "\nhostCall(\"echo\", \"\");\n" <> driver
File.write!("/tmp/combined_src.js", combined)
IO.puts("wrote combined #{byte_size(combined)}")
