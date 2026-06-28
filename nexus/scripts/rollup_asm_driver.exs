# Porffor ASM-lane Rollup driver (durable — replaces the lost /tmp scaffold).
#
# Assembles the Rollup bundle for the Porffor->Washy ASM (shipping) lane and runs it, reporting where it
# lands (BUNDLE_OK, a JS throw, or a wasm trap). The QuickJS oracle (test/washy_rollup_bundle_test.exs) gets
# require/fs/globalThis for free; the Porffor lane must assemble them: host_prelude (byte __host bridge) +
# the compiled node shims (compilers/js/node/*.js) + shim_prelude (fs/promises/path.win32 overlay) + the
# 1.27MB bundle. Imports a=print b=printChar c/d=time e=PorfforHost.host_call (rollup_parse → HostRollup).
#
# Run: mix run scripts/rollup_asm_driver.exs   (slow: 1.27MB JS -> ~96MB wasm, multi-minute run)

dir = Path.join(__DIR__, "../test/conformance/rollup")

host_prelude = File.read!(Path.join(__DIR__, "../compilers/js/porffor/host_prelude.js"))

# node shims in filename order; drop 63_console (QuickJS Javy.IO — Porffor has native console.log).
shims =
  Path.wildcard(Path.join(__DIR__, "../compilers/js/node/*.js"))
  |> Enum.sort()
  |> Enum.reject(&String.contains?(&1, "63_console"))
  |> Enum.map(&File.read!/1)
  |> Enum.join("\n")

shim_prelude = File.read!(Path.join(dir, "shim_prelude.js"))
bundle = File.read!(Path.join(dir, "rollup_bundle.cjs"))
golden = File.read!(Path.join(dir, "rollup_bundle_golden.js"))

src = Enum.join([host_prelude, shims, shim_prelude, bundle], "\n")
IO.puts("[driver] assembled source: #{byte_size(src)} bytes")

t0 = System.monotonic_time(:millisecond)

case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} ->
    IO.puts("[driver] compiled: #{byte_size(wasm)} bytes wasm in #{System.monotonic_time(:millisecond) - t0}ms")

    case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true, timeout_ms: 480_000) do
      {:ok, out} ->
        tail = String.slice(out, max(0, String.length(out) - 600), 600)
        IO.puts("[driver] RAN. output tail:\n#{tail}")

        if String.contains?(out, "BUNDLE_OK[") do
          code = out |> String.split("BUNDLE_OK[", parts: 2) |> List.last() |> String.trim_trailing("\n") |> String.replace_suffix("]", "")
          IO.puts(if code == golden, do: "[driver] ✅ BYTE-IDENTICAL to golden", else: "[driver] ⚠ BUNDLE_OK but differs from golden")
        else
          IO.puts("[driver] no BUNDLE_OK — frontier is above (see output tail / trap)")
        end

      err ->
        IO.puts("[driver] RUN ERROR (the frontier): #{inspect(err)}")
    end

  err ->
    IO.puts("[driver] COMPILE FAILED: #{inspect(err)}")
end
