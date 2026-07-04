# Copies a CURATED STARTER SLICE from the gitignored full clone (.test262/) into the committed path
# test/conformance/test262/. Curated to cover the language regions the conformance ladder keeps hitting.
# Run:  mix run scripts/test262-vendor-slice.exs
#
# The slice is intentionally small (a few hundred files, NOT the ~50k full suite). The WHY for each dir is
# documented in test/conformance/test262/manifest.work (the .work source of truth — NO JSON).

clone = Path.join(File.cwd!(), ".test262")
unless File.dir?(clone), do: raise("clone missing: #{clone} — run: git clone --depth 1 https://github.com/tc39/test262 .test262")

dest = Path.join([File.cwd!(), "test", "conformance", "test262"])
cases = Path.join(dest, "cases")
harness_dest = Path.join(dest, "harness")

# {test262 subdir under test/, max files to take}. nil = take all top-level .js (small dirs).
slice = [
  {"language/statements/for-of", 60},
  {"language/statements/for-in", 40},
  {"language/statements/let", nil},
  {"language/statements/const", nil},
  {"language/statements/for", 30},        # head-*-fresh-binding-per-iteration lives here
  {"language/expressions/generators", 40},
  {"language/expressions/yield", 30},
  {"language/statements/generators", 40},
  {"built-ins/RegExp", 80},
  {"built-ins/RegExp/prototype", nil},
  {"built-ins/BigInt", nil},
  {"built-ins/Proxy", nil},

  # ── v2 additions (2026-07-04, probe-curated) ────────────────────────────────────────────────
  # The v1 dozen covered 0.9% of the corpus and no built-ins bulk — full runs kept surprising low.
  # These regions come from the stratified probe (scripts/test262-probe.exs) weakness map; each is
  # sampled with an EVEN STRIDE over the region's whole recursive tree (:stride), not first-N
  # alphabetical, so the sample represents the region. v1 entries keep head-N for continuity of the
  # historical 419-case numbers.
  {"built-ins/TypedArray/prototype", {:stride, 40}},   # probe  2.5% — weakest region measured
  {"built-ins/Promise", {:stride, 40}},                #        21%  (sync part; async auto-skips)
  {"built-ins/Error", {:stride, 40}},                  #        37.5%
  {"built-ins/ArrayBuffer", {:stride, 30}},            #        40%
  {"built-ins/DataView", {:stride, 30}},               #        42.5%
  {"built-ins/Symbol", {:stride, 40}},                 #        42.5%
  {"built-ins/JSON", {:stride, 40}},                   #        47.5%
  {"built-ins/Map", {:stride, 30}},                    #        47.5%
  {"built-ins/Array", {:stride, 40}},                  #        51.3%
  {"built-ins/Set", {:stride, 30}},                    #        55%
  {"built-ins/Function", {:stride, 30}},               #        57.5%
  {"built-ins/Function/prototype", {:stride, 30}},     #        60%
  {"built-ins/String/prototype", {:stride, 40}},       #        60%
  {"language/statements/switch", {:stride, 30}},       #        62.5%
  {"built-ins/Reflect", {:stride, 30}},                #        65%
  {"built-ins/Array/prototype", {:stride, 40}},        #        67.5%
  {"language/statements/try", {:stride, 30}},          #        75%
  {"language/expressions/assignment/dstr", {:stride, 30}}, #    75%
  {"language/statements/class", {:stride, 30}},        #        75.8%
  {"built-ins/Object", {:stride, 30}}                  #        77.5%
]

File.rm_rf!(cases)
File.mkdir_p!(cases)
File.mkdir_p!(harness_dest)

total =
  Enum.reduce(slice, 0, fn {sub, cap}, acc ->
    srcdir = Path.join([clone, "test", sub])

    files =
      case cap do
        {:stride, n} ->
          # even-stride sample over the WHOLE region tree (recursive) — represents the region
          all =
            Path.wildcard(Path.join(srcdir, "**/*.js"))
            |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
            |> Enum.sort()

          total = length(all)

          if total <= n do
            all
          else
            stride = total / n
            Enum.map(0..(n - 1), fn i -> Enum.at(all, min(trunc(i * stride), total - 1)) end)
          end

        _ ->
          Path.wildcard(Path.join(srcdir, "*.js"))
          |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
          |> Enum.sort()
          |> then(fn fs -> if cap, do: Enum.take(fs, cap), else: fs end)
      end

    outdir = Path.join(cases, sub)
    File.mkdir_p!(outdir)
    # Preserve each file's path relative to the region (stride samples recurse into subdirs) and
    # bring along _FIXTURE.js siblings from every directory a taken file lives in.
    fixdirs = files |> Enum.map(&Path.dirname/1) |> Enum.uniq()
    fixtures = Enum.flat_map(fixdirs, fn d -> Path.wildcard(Path.join(d, "*_FIXTURE.js")) end)

    Enum.each(files ++ fixtures, fn f ->
      rel = Path.relative_to(f, srcdir)
      dest = Path.join(outdir, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(f, dest)
    end)
    IO.puts("  #{sub}: #{length(files)} cases")
    acc + length(files)
  end)

# Vendor ONLY the harness includes the slice actually references (+ the always-needed assert/sta).
referenced =
  Path.wildcard(Path.join(cases, "**/*.js"))
  |> Enum.flat_map(fn f ->
    case Regex.run(~r{includes:\s*\[(.*?)\]}, File.read!(f), capture: :all_but_first) do
      [items] -> items |> String.split(",") |> Enum.map(&String.trim/1)
      _ -> []
    end
  end)
  |> Enum.uniq()

needed = Enum.uniq(["assert.js", "sta.js", "propertyHelper.js", "compareArray.js", "isConstructor.js" | referenced])

Enum.each(needed, fn name ->
  src = Path.join([clone, "harness", name])
  if File.regular?(src), do: File.cp!(src, Path.join(harness_dest, name))
end)

IO.puts("\nvendored #{total} cases + #{length(File.ls!(harness_dest))} harness files → #{Path.relative_to_cwd(dest)}")
