# STRATIFIED PROBE of the full test262 clone on the ASM lane — the instrument for curating the hard
# slice. Samples N cases per region with an EVEN SPREAD (every k-th file after sort — not first-N
# alphabetical, which biases toward one API corner), runs each region in OS-isolated batches, prints a
# per-region pass map. Use the map to pick weak regions for the committed slice (vendor-slice v2).
#
#   mix run --no-compile scripts/test262-probe.exs                 # all regions below, N=40
#   N=25 REGIONS=built-ins/Array,built-ins/JSON mix run --no-compile scripts/test262-probe.exs
#
# Worker mode (internal): REGION + START/COUNT set → run that window, print BATCH/SIG lines.

clone = Path.join(File.cwd!(), ".test262")
testdir = Path.join(clone, "test")
hdir = Path.join(clone, "harness")

default_regions = ~w(
  language/expressions/class
  language/statements/class
  language/expressions/assignment
  language/expressions/assignment/dstr
  language/expressions/arrow-function
  language/expressions/object
  language/expressions/template-literal
  language/expressions/optional-chaining
  language/statements/try
  language/statements/switch
  language/types
  built-ins/Array
  built-ins/Array/prototype
  built-ins/Object
  built-ins/Object/defineProperty
  built-ins/String/prototype
  built-ins/Function/prototype
  built-ins/Symbol
  built-ins/Reflect
  built-ins/Map
  built-ins/Set
  built-ins/JSON
  built-ins/Promise
  built-ins/TypedArray/prototype
  built-ins/ArrayBuffer
  built-ins/DataView
  built-ins/Date
  built-ins/Error
  built-ins/Function
  built-ins/Number
  built-ins/Boolean
  built-ins/Math
)

n = String.to_integer(System.get_env("N", "40"))
batch = String.to_integer(System.get_env("BATCH", "20"))

regions =
  case System.get_env("REGIONS") do
    nil -> default_regions
    s -> String.split(s, ",", trim: true)
  end

# Even-spread sample: k = total/n stride over the sorted list (deterministic, covers the whole dir tree
# under the region including subdirs — recursive wildcard).
sample = fn region ->
  all =
    Path.wildcard(Path.join([testdir, region, "**", "*.js"]))
    |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
    |> Enum.sort()

  total = length(all)

  cond do
    total == 0 -> []
    total <= n -> all
    true ->
      stride = total / n
      Enum.map(0..(n - 1), fn i -> Enum.at(all, min(trunc(i * stride), total - 1)) end)
  end
end

if region = System.get_env("REGION") do
  # ── WORKER ──────────────────────────────────────────────────────────────────────────────
  files = sample.(region)
  s = String.to_integer(System.get_env("START", "0"))
  count = String.to_integer(System.get_env("COUNT", "#{batch}"))
  window = Enum.slice(files, s, count)

  results =
    Enum.map(window, fn f ->
      Nexus.Test262.run_file(f, rel: Path.relative_to(f, testdir), harness_dir: hdir, fuel: 500_000_000)
    end)

  sm = Nexus.Test262.summarize(results)
  IO.puts("BATCH\t#{s}\t#{sm.total}\t#{sm.pass}\t#{sm.fail}\t#{sm.skip}")
  for {sig, rels} <- sm.by_signature, do: IO.puts("SIG\t#{length(rels)}\t#{sig}\t#{Enum.join(Enum.take(rels, 3), ",")}")
else
  # ── DRIVER ──────────────────────────────────────────────────────────────────────────────
  out_path = System.get_env("OUT", "/tmp/t262_probe.tsv")
  File.write!(out_path, "")
  IO.puts("# stratified probe: #{length(regions)} regions × up to #{n} cases → #{out_path}")

  Enum.each(regions, fn region ->
    files = sample.(region)
    total = length(files)

    if total == 0 do
      IO.puts("#{String.pad_trailing(region, 44)} MISSING (no files)")
    else
      {pass, fail, skip, crashed, sigs} =
        Enum.reduce(Enum.to_list(0..(total - 1)//batch), {0, 0, 0, 0, %{}}, fn s, {p, f, sk, cr, acc} ->
          env = [
            {"REGION", region},
            {"START", "#{s}"},
            {"COUNT", "#{batch}"},
            {"BATCH", "#{batch}"},
            {"N", "#{n}"}
          ]

          {out, code} =
            System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "scripts/test262-probe.exs"],
              env: env,
              stderr_to_stdout: true
            )

          bline = out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "BATCH\t"))

          case String.split(bline, "\t") do
            ["BATCH", _s, _t, bp, bf, bsk] ->
              acc2 =
                out
                |> String.split("\n")
                |> Enum.filter(&String.starts_with?(&1, "SIG\t"))
                |> Enum.reduce(acc, fn l, a ->
                  ["SIG", cnt, sig | _] = String.split(l, "\t")
                  Map.update(a, sig, String.to_integer(cnt), &(&1 + String.to_integer(cnt)))
                end)

              {p + String.to_integer(bp), f + String.to_integer(bf), sk + String.to_integer(bsk), cr, acc2}

            _ ->
              win = min(batch, total - s)
              {p, f, sk, cr + win, Map.update(acc, "crash:batch", win, &(&1 + win))}
          end
        end)

      ran = pass + fail
      pct = if ran > 0, do: Float.round(pass * 100 / ran, 1), else: 0.0
      topsigs =
        sigs
        |> Enum.sort_by(fn {_, c} -> -c end)
        |> Enum.take(3)
        |> Enum.map(fn {sig, c} -> "[#{c}] #{sig}" end)
        |> Enum.join("  ")

      line = "#{region}\t#{pass}/#{ran}\t#{pct}%\tskip=#{skip} crash=#{crashed}\t#{topsigs}"
      File.write!(out_path, line <> "\n", [:append])
      IO.puts("#{String.pad_trailing(region, 44)} #{pass}/#{ran} (#{pct}%)  skip=#{skip} crash=#{crashed}  #{topsigs}")
    end
  end)

  IO.puts("done → #{out_path}")
end
