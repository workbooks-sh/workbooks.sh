# Marked corpus runner: each case compiled+run in a FRESH wasm instance (avoids the no-GC accumulation),
# byte-compared to the node golden. Proves marked-4.3.0 byte-identical on the chosen lane.
prelude = File.read!("test/conformance/porffor_cjs/cjs_prelude.js")
marked = File.read!("test/conformance/marked-4.3.0.js")
transpile = System.get_env("LANE") != "interp"

pairs =
  File.read!("/tmp/corpus_b64.txt")
  |> String.split("\n", trim: true)
  |> Enum.map(fn line ->
    [i, o] = String.split(line, "\t")
    {Base.decode64!(i), Base.decode64!(o)}
  end)

# CASE=<idx> runs only that one case (OS-process isolation against BEAM-VM crashes).
pairs =
  case System.get_env("CASE") do
    nil -> pairs
    idx -> [Enum.at(pairs, String.to_integer(idx))]
  end

# JS string literal for an arbitrary input (JSON encoding is valid JS)
jslit = fn s -> Jason.encode!(s) end

{pass, fail} =
  Enum.reduce(pairs, {0, []}, fn {input, golden}, {p, fails} ->
    driver = "\n;\nvar parse=module.exports.parse;console.log(parse(#{jslit.(input)}));\n"
    src = prelude <> "\n" <> marked <> driver
    # console.log appends exactly one "\n" on top of marked's own trailing newline.
    golden = golden <> "\n"

    # Use the lazy-transpile path (Nexus.Porffor.Debug) not Sandbox.run_command: Sandbox PREWARMS (eager
    # transpile) which currently miscompiles (G5 "prewarm bit-identical"), dropping chars. The lazy path
    # transpiles hot functions on the same ASM lane without the prewarm miscompile.
    got =
      case Nexus.Porffor.Debug.diagnose(src, fuel: 4_000_000_000, transpile: transpile) do
        {:ok, %{completed: true, output: out}} -> out
        {:ok, r} -> "RUN_ERR #{inspect(r.trap || r.error)}"
        e -> "COMPILE_ERR #{inspect(e)}"
      end

    if got == golden do
      {p + 1, fails}
    else
      {p, [{input, golden, got} | fails]}
    end
  end)

lane = if transpile, do: "ASM", else: "interp"
IO.puts("\n=== marked corpus on #{lane} lane: #{pass}/#{length(pairs)} byte-identical ===")

for {input, golden, got} <- Enum.reverse(fail) do
  IO.puts("FAIL input=#{inspect(input)}\n  want=#{inspect(golden)}\n  got =#{inspect(got)}")
end
