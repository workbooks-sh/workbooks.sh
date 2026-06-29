# Per-case pass/fail SET for generator-using test262 cases — run each ALONE (no batch contamination), with
# a per-case timeout (so an infinite generator on the eager path can't hang/poison the run). Emit
# "<rel>\t<PASS|FAIL:sig|SKIP|TIMEOUT>" per case. Run once fiber-on, once fiber-off (toggle the transform),
# then diff the two outputs to get the REAL regression set — not the signature histogram.

regions = [
  "language/statements/generators",
  "language/expressions/generators",
  "language/statements/for-of",
  "language/expressions/yield"
]

base = Path.join(__DIR__, "../test/conformance/test262/cases")

cases =
  regions
  |> Enum.flat_map(fn r -> Path.wildcard(Path.join([base, r, "**/*.js"])) end)
  |> Enum.sort()

for path <- cases do
  rel = Path.relative_to(path, base)

  status =
    try do
      t = Task.async(fn -> Nexus.Test262.run_file(path) end)

      case Task.yield(t, 10_000) || Task.shutdown(t, :brutal_kill) do
        {:ok, %{status: :pass}} -> "PASS"
        {:ok, %{status: {:skip, _}}} -> "SKIP"
        {:ok, %{status: s}} -> "FAIL:" <> (Nexus.Test262.signature(%Nexus.Test262.Result{status: s}) |> String.slice(0, 40))
        _ -> "TIMEOUT"
      end
    rescue
      _ -> "ERR"
    catch
      _, _ -> "ERR"
    end

  IO.puts("#{rel}\t#{status}")
end
