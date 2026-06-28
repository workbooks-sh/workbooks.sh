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

# Optional --pageSize stopgap (PAGESIZE=262144 mix run …) to probe whether object-capacity is the WHOLE wall.
flags = case System.get_env("PAGESIZE") do
  nil -> []
  ps -> IO.puts("[driver] PAGESIZE stopgap: --pageSize=#{ps}"); ["--pageSize=#{ps}"]
end

# Cache the 97MB wasm keyed by (source + flags) so re-runs skip the ~35-60s compile (the inner-loop tax).
cache_key = :crypto.hash(:sha256, src <> Enum.join(flags, ",")) |> Base.encode16(case: :lower) |> String.slice(0, 16)
cache = Path.join(System.tmp_dir!(), "rollup_asm_#{cache_key}.wasm")

t0 = System.monotonic_time(:millisecond)

compiled =
  if File.exists?(cache) do
    IO.puts("[driver] using cached wasm #{cache}")
    {:ok, File.read!(cache)}
  else
    case Nexus.Compilers.Js.Porffor.compile(src, Nexus.Compilers.Shared.default_root(), flags: flags) do
      {:ok, w} -> File.write!(cache, w); {:ok, w}
      e -> e
    end
  end

case compiled do
  {:ok, wasm} ->
    IO.puts("[driver] compiled: #{byte_size(wasm)} bytes wasm in #{System.monotonic_time(:millisecond) - t0}ms")

    # Run inline (NOT via Porffor.run, which loses output on a trap): keep :porffor_out so we can see what
    # was PRINTED right before any trap — e.g. the object-capacity guard's 888888888 sentinel + obj/size/cap.
    {:ok, mod} = Nexus.Washy.decode(wasm)
    Process.put(:porffor_out, [])
    fmt = fn v -> if v == Float.round(v) and abs(v) < 1.0e15, do: Integer.to_string(trunc(v)), else: Float.to_string(v) end
    emit = fn s -> Process.put(:porffor_out, [s | Process.get(:porffor_out, [])]) end

    Process.put(:washy_imports, %{
      "a" => fn [v] -> emit.(fmt.(v)); nil end,
      "b" => fn [v] -> emit.(<<trunc(v)::utf8>>); nil end,
      "c" => fn _ -> 0.0 end,
      "d" => fn _ -> 0.0 end,
      "e" => &Nexus.Compilers.Js.PorfforHost.host_call/1
    })

    result =
      try do
        Nexus.Washy.instance_start(mod, "m", [], transpile: true)
      catch
        kind, val -> {:caught, kind, val}
      rescue
        e -> {:rescued, Exception.message(e)}
      end

    out = Process.get(:porffor_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    tail = String.slice(out, max(0, String.length(out) - 800), 800)
    IO.puts("[driver] result: #{inspect(result) |> String.slice(0, 200)}")
    IO.puts("[driver] output tail:\n#{tail}")

    cond do
      String.contains?(out, "BUNDLE_OK[") ->
        code = out |> String.split("BUNDLE_OK[", parts: 2) |> List.last() |> String.trim_trailing("\n") |> String.replace_suffix("]", "")
        IO.puts(if code == golden, do: "[driver] ✅ BYTE-IDENTICAL to golden", else: "[driver] ⚠ BUNDLE_OK but differs from golden")

      String.contains?(out, "888888888") ->
        IO.puts("[driver] FRONTIER = OBJECT CAPACITY OVERFLOW (the 888888888 guard fired — obj/size/cap above)")

      true ->
        IO.puts("[driver] FRONTIER = trap/throw with no object-guard sentinel (see tail + result)")
    end

  err ->
    IO.puts("[driver] COMPILE FAILED: #{inspect(err)}")
end
