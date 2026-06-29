# Per-case test262 verdicts on OUR ASM lane → /tmp/ours_percase.tsv (rel<TAB>pass|fail|skip).
# OS-isolated batches (fresh `mix run` per batch) so a SIGABRT can't lose the run. Mirrors
# scripts/test262-run-isolated.exs but emits one line per case instead of batch tallies.
base = Path.join(["test", "conformance", "test262"])
hdir = Path.join(base, "harness")
absdir = Path.join(base, "cases")

files =
  Path.wildcard(Path.join(absdir, "**/*.js"))
  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
  |> Enum.sort()

start = System.get_env("START")
batch = String.to_integer(System.get_env("BATCH", "20"))

verdict = fn status ->
  cond do
    status == :pass -> "pass"
    match?({:skip, _}, status) -> "skip"
    true -> "fail"
  end
end

if start do
  s = String.to_integer(start)
  count = String.to_integer(System.get_env("COUNT", "#{batch}"))
  window = Enum.slice(files, s, count)

  Enum.each(window, fn f ->
    rel = Path.relative_to(f, absdir)

    v =
      try do
        r = Nexus.Test262.run_file(f, rel: rel, harness_dir: hdir, fuel: 500_000_000)
        verdict.(r.status)
      rescue
        _ -> "fail"
      catch
        _, _ -> "fail"
      end

    IO.puts("CASE\t#{rel}\t#{v}")
  end)
else
  total = length(files)
  out = "/tmp/ours_percase.tsv"
  File.write!(out, "")
  IO.puts("# ours per-case: #{total} files, batch=#{batch}")

  Enum.reduce(0..max(total - 1, 0)//batch, 0, fn s, done ->
    env = [{"START", "#{s}"}, {"COUNT", "#{batch}"}, {"BATCH", "#{batch}"}]
    {o, code} = System.cmd("mix", ["run", "scripts/test262-percase.exs"], env: env, stderr_to_stdout: true)

    lines =
      o
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "CASE\t"))
      |> Enum.map(&String.replace_prefix(&1, "CASE\t", ""))

    if lines == [] do
      win = min(batch, total - s)
      IO.puts("  batch @#{s} CRASHED (exit #{code}) — #{win} cases lost")
      # record crashed window as fail so the diff still has rows
      crashed =
        Enum.slice(files, s, win)
        |> Enum.map(fn f -> "#{Path.relative_to(f, absdir)}\tfail" end)

      File.write!(out, Enum.join(crashed, "\n") <> "\n", [:append])
    else
      File.write!(out, Enum.join(lines, "\n") <> "\n", [:append])
    end

    d = done + length(lines)
    IO.puts("  ...#{d}/#{total}")
    d
  end)

  IO.puts("DONE ours per-case -> #{out}")
end
