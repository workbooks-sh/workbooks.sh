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
  {"built-ins/Proxy", nil}
]

File.rm_rf!(cases)
File.mkdir_p!(cases)
File.mkdir_p!(harness_dest)

total =
  Enum.reduce(slice, 0, fn {sub, cap}, acc ->
    srcdir = Path.join([clone, "test", sub])
    files =
      Path.wildcard(Path.join(srcdir, "*.js"))
      |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
      |> Enum.sort()
      |> then(fn fs -> if cap, do: Enum.take(fs, cap), else: fs end)

    outdir = Path.join(cases, sub)
    File.mkdir_p!(outdir)
    # Bring along _FIXTURE.js siblings any taken file may reference.
    fixtures = Path.wildcard(Path.join(srcdir, "*_FIXTURE.js"))
    Enum.each(files ++ fixtures, fn f -> File.cp!(f, Path.join(outdir, Path.basename(f))) end)
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
