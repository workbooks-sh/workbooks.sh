# Per-FAILING-case detail on the ASM lane → one line per fail: rel<TAB>signature<TAB>error-desc.
# OS-isolated batches (fresh `mix run` per batch, same pattern as test262-run-isolated.exs) so a
# SIGABRT loses at most one window. Use to triage the throw:Test262Error catch-all — the desc carries
# the assert message, which names the mismatched value.
#
#   DIR=cases mix run scripts/test262-detail.exs                      # whole slice → /tmp/t262_detail.tsv
#   DIR=cases/built-ins/RegExp mix run scripts/test262-detail.exs
base = Path.join(["test", "conformance", "test262"])
hdir = Path.join(base, "harness")
dir = System.get_env("DIR", "cases")
absdir = if String.starts_with?(dir, "/"), do: dir, else: Path.join(base, dir)

files =
  Path.wildcard(Path.join(absdir, "**/*.js"))
  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
  |> Enum.sort()

start = System.get_env("START")
batch = String.to_integer(System.get_env("BATCH", "20"))
out_path = System.get_env("OUT", "/tmp/t262_detail.tsv")

desc = fn status ->
  case status do
    {:fail, :unexpected_throw, d} -> d
    {:fail, :wrong_error, want, got} -> "want=#{want} got=#{got}"
    {:fail, :no_throw, want} -> "no_throw expected=#{want}"
    {:fail, :trap, reason} -> "trap:#{inspect(reason)}"
    {:fail, :compile_error, msg} -> "compile:#{String.slice(inspect(msg), 0, 200)}"
    other -> inspect(other, limit: 6)
  end
end

if start do
  s = String.to_integer(start)
  count = String.to_integer(System.get_env("COUNT", "#{batch}"))
  window = Enum.slice(files, s, count)

  Enum.each(window, fn f ->
    rel = Path.relative_to(f, absdir)

    try do
      r = Nexus.Test262.run_file(f, rel: rel, harness_dir: hdir, fuel: 500_000_000)

      case r.status do
        :pass -> :ok
        {:skip, _} -> :ok
        st -> IO.puts("FAILCASE\t#{rel}\t#{Nexus.Test262.signature(st)}\t#{desc.(st) |> to_string() |> String.replace(["\n", "\t"], " ") |> String.slice(0, 300)}")
      end
    rescue
      e -> IO.puts("FAILCASE\t#{rel}\traised\t#{Exception.message(e) |> String.slice(0, 200)}")
    catch
      k, v -> IO.puts("FAILCASE\t#{rel}\tcaught:#{k}\t#{inspect(v, limit: 4) |> String.slice(0, 200)}")
    end
  end)
else
  total = length(files)
  IO.puts("# detail run: #{total} files in #{absdir}, batch=#{batch} → #{out_path}")
  File.write!(out_path, "")

  Enum.each(Enum.to_list(0..max(total - 1, 0)//batch), fn s ->
    env = [{"START", "#{s}"}, {"COUNT", "#{batch}"}, {"BATCH", "#{batch}"}, {"DIR", dir}]

    {out, code} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "scripts/test262-detail.exs"],
        env: env,
        stderr_to_stdout: true
      )

    faillines =
      out
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "FAILCASE\t"))
      |> Enum.map(&String.replace_prefix(&1, "FAILCASE\t", ""))

    crashed = if code != 0 and faillines == [], do: ["@#{s}\tbatch_crashed\texit=#{code}"], else: []
    File.write!(out_path, Enum.join(faillines ++ crashed, "\n") <> if(faillines ++ crashed == [], do: "", else: "\n"), [:append])
    IO.puts("[#{min(s + batch, total)}/#{total}] +#{length(faillines)} fails")
  end)

  IO.puts("done → #{out_path}")
end
