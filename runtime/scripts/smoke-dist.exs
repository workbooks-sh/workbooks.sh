# Validate the lean compilers-dist bundle: compile a minimal program per lane with root pinned
# to "compilers-dist" (NOT the full compilers/ tree). A missing runtime file surfaces as a compile
# error here. Run: mix run scripts/smoke-dist.exs
alias Workbooks.Compilers
root = "compilers-dist"
tmp = System.tmp_dir!()
w = fn name, body -> p = Path.join(tmp, "smoke_#{name}_#{System.unique_integer([:positive])}"); File.write!(p, body); p end

probe = fn label, fun ->
  result =
    try do
      case fun.() do
        {:ok, wasm, _} when is_binary(wasm) -> "OK (#{byte_size(wasm)} B)"
        {:ok, wasm} when is_binary(wasm) -> "OK (#{byte_size(wasm)} B)"
        {:ok, out} -> "OK (ran: #{String.trim(to_string(out)) |> String.slice(0, 30)})"
        {:error, r} -> "FAIL: #{inspect(r) |> String.slice(0, 120)}"
        other -> "?? #{inspect(other) |> String.slice(0, 80)}"
      end
    rescue
      e -> "RAISED: #{Exception.message(e) |> String.slice(0, 120)}"
    end
  IO.puts("  [#{label}] #{result}")
end

IO.puts("== smoke: compilers-dist (lean bundle) ==")

probe.("c", fn ->
  src = w.("c.c", "int main(){return 0;}\n")
  Compilers.compile_c(src, [], root)
end)

probe.("zig", fn ->
  src = w.("z.zig", "pub fn main() void {}\n")
  Compilers.zig_compile_to_wasm(src, [], root)
end)

probe.("js", fn ->
  src = w.("j.js", "console.log('hi');\n")
  Compilers.js_compile_to_wasm(src, [], root)
end)

probe.("rust", fn ->
  src = w.("r.rs", "fn main() { println!(\"ok\"); }\n")
  Compilers.rust_compile_to_wasm(src, [no_exceptions: true], root)
end)

IO.puts("== done ==")
