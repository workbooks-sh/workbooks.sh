# PARALLEL driver for the FULL tc39/test262 run on the Porffor→Washy ASM lane.
# Spawns K concurrent OS workers (each `mix run --no-compile scripts/test262-full-run.exs` with a
# START/COUNT window — the worker side of test262-full-run.exs, unchanged). Aggregation is commutative
# (sums), so completion order doesn't matter. Live summary → /tmp/test262_full_summary.txt after every
# batch. Run the driver with plain `elixir` so it never touches the mix build lock:
#
#   cd nexus && mix compile && elixir scripts/test262-full-par.exs        # K=6 default
#   K=4 BATCH=30 elixir scripts/test262-full-par.exs
#
# Workers run --no-compile --no-deps-check so concurrent workers never write _build (serialize-mix rule:
# compile once up front, then all mix invocations are read-only).

clone = Path.join(File.cwd!(), ".test262")
testdir = Path.join(clone, "test")

files =
  Path.wildcard(Path.join(testdir, "**/*.js"))
  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
  |> Enum.sort()

total = length(files)
batch = String.to_integer(System.get_env("BATCH", "30"))
k = String.to_integer(System.get_env("K", "6"))
summary_path = "/tmp/test262_full_summary.txt"

IO.puts("# FULL test262 PARALLEL: #{total} cases, batch=#{batch}, workers=#{k} — live → #{summary_path}")

starts = Enum.to_list(0..max(total - 1, 0)//batch)

run_worker = fn s ->
  env = [{"START", "#{s}"}, {"COUNT", "#{batch}"}, {"BATCH", "#{batch}"}]

  {out, code} =
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "scripts/test262-full-run.exs"],
      env: env,
      stderr_to_stdout: true
    )

  {s, out, code}
end

agg = :ets.new(:agg, [:public, :set])
:ets.insert(agg, {:tot, 0, 0, 0, 0, 0})

flush = fn ->
  [{:tot, p, f, sk, cr, done}] = :ets.lookup(agg, :tot)
  ran = p + f
  pct = if ran > 0, do: Float.round(p * 100 / ran, 2), else: 0.0

  reglines =
    :ets.tab2list(agg)
    |> Enum.filter(fn t -> elem(t, 0) != :tot end)
    |> Enum.sort()
    |> Enum.map(fn {reg, rp, rt} ->
      rpct = if rt > 0, do: Float.round(rp * 100 / rt, 1), else: 0.0
      "  #{String.pad_trailing(reg, 12)} #{rp}/#{rt} (#{rpct}%)"
    end)
    |> Enum.join("\n")

  File.write!(summary_path, """
  # FULL tc39/test262 on Porffor→Washy ASM lane (live, parallel K workers)
  cases seen: #{done}/#{total}   pass #{p}/#{ran} (#{pct}%)   skip #{sk}   crashed #{cr}
  per top-level region:
  #{reglines}
  """)

  {done, p, ran, pct, sk, cr}
end

starts
|> Task.async_stream(run_worker, max_concurrency: k, timeout: :infinity, ordered: false)
|> Enum.each(fn {:ok, {s, out, code}} ->
  lines = String.split(out, "\n")
  bline = Enum.find(lines, "", &String.starts_with?(&1, "BATCH\t"))
  win = min(batch, total - s)

  case String.split(bline, "\t") do
    ["BATCH", _s, _t, bp, bf, bsk] ->
      :ets.update_counter(agg, :tot, [
        {2, String.to_integer(bp)},
        {3, String.to_integer(bf)},
        {4, String.to_integer(bsk)},
        {5, 0},
        {6, win}
      ])

      lines
      |> Enum.filter(&String.starts_with?(&1, "REG\t"))
      |> Enum.each(fn l ->
        ["REG", reg, rp, rt] = String.split(l, "\t")

        case :ets.lookup(agg, reg) do
          [] -> :ets.insert(agg, {reg, String.to_integer(rp), String.to_integer(rt)})
          _ -> :ets.update_counter(agg, reg, [{2, String.to_integer(rp)}, {3, String.to_integer(rt)}])
        end
      end)

    _ ->
      IO.puts("  batch @#{s} CRASHED (exit #{code}) — #{win} cases counted crashed")
      :ets.update_counter(agg, :tot, [{2, 0}, {3, 0}, {4, 0}, {5, win}, {6, win}])
  end

  {done, p, ran, pct, sk, cr} = flush.()
  if rem(done, batch * 25) < batch, do: IO.puts("[#{done}/#{total}] pass #{p}/#{ran} (#{pct}%) skip #{sk} crashed #{cr}")
end)

{done, p, ran, pct, sk, cr} = flush.()
IO.puts("\n=== FULL test262 DONE: pass #{p}/#{ran} (#{pct}%) skip #{sk} crashed #{cr} seen #{done}/#{total} ===")
