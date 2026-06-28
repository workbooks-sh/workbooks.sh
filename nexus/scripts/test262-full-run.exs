# Full tc39/test262 (~53k cases) on the Porffor→Washy ASM lane, OS-isolated batches so a no-GC SIGABRT
# in one batch is reported as crashed cases, not a lost run. Writes INCREMENTAL progress to
# /tmp/test262_full_summary.txt (running pass% overall + per top-level region) after every batch, so the
# run can be sampled live. Uses the FULL clone's harness (.test262/harness), not the committed slice's.
#
#   mix run scripts/test262-full-run.exs              # DRIVER: runs the whole .test262/test tree
#   START=0 COUNT=30 mix run scripts/test262-full-run.exs   # WORKER (internal)

clone = Path.join(File.cwd!(), ".test262")
testdir = Path.join(clone, "test")
hdir = Path.join(clone, "harness")

files =
  Path.wildcard(Path.join(testdir, "**/*.js"))
  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
  |> Enum.sort()

batch = String.to_integer(System.get_env("BATCH", "30"))
start = System.get_env("START")

region = fn rel -> rel |> Path.split() |> List.first() end

if start do
  # ── WORKER: run window [START, START+COUNT) ──────────────────────────────────────────────
  s = String.to_integer(start)
  count = String.to_integer(System.get_env("COUNT", "#{batch}"))
  window = Enum.slice(files, s, count)

  {pass, fail, skip, regacc} =
    Enum.reduce(window, {0, 0, 0, %{}}, fn f, {p, fl, sk, racc} ->
      rel = Path.relative_to(f, testdir)
      reg = region.(rel)
      st =
        try do
          r = Nexus.Test262.run_file(f, rel: rel, harness_dir: hdir, fuel: 500_000_000)
          case r.status do
            :pass -> :pass
            {:skip, _} -> :skip
            _ -> :fail
          end
        rescue
          _ -> :fail
        catch
          _, _ -> :fail
        end

      {dp, dfl, dsk} = case st do
        :pass -> {1, 0, 0}
        :skip -> {0, 0, 1}
        _ -> {0, 1, 0}
      end

      racc = Map.update(racc, reg, {dp, dp + dfl}, fn {rp, rt} -> {rp + dp, rt + dp + dfl} end)
      {p + dp, fl + dfl, sk + dsk, racc}
    end)

  IO.puts("BATCH\t#{s}\t#{length(window)}\t#{pass}\t#{fail}\t#{skip}")
  for {reg, {rp, rt}} <- regacc, do: IO.puts("REG\t#{reg}\t#{rp}\t#{rt}")
else
  # ── DRIVER: spawn one OS worker per batch, accumulate, write live summary ─────────────────
  total = length(files)
  summary_path = "/tmp/test262_full_summary.txt"
  IO.puts("# FULL test262 run: #{total} cases, batch=#{batch} — live summary → #{summary_path}")

  starts = Enum.to_list(0..max(total - 1, 0)//batch)

  Enum.reduce(starts, {0, 0, 0, 0, %{}, 0}, fn s, {p, f, sk, cr, regs, done} ->
    env = [{"START", "#{s}"}, {"COUNT", "#{batch}"}, {"BATCH", "#{batch}"}]
    {out, code} = System.cmd("mix", ["run", "scripts/test262-full-run.exs"], env: env, stderr_to_stdout: true)
    lines = String.split(out, "\n")
    bline = Enum.find(lines, "", &String.starts_with?(&1, "BATCH\t"))

    {p2, f2, sk2, cr2, regs2} =
      case String.split(bline, "\t") do
        ["BATCH", _s, _t, bp, bf, bsk] ->
          regs_new =
            lines
            |> Enum.filter(&String.starts_with?(&1, "REG\t"))
            |> Enum.reduce(regs, fn l, acc ->
              ["REG", reg, rp, rt] = String.split(l, "\t")
              Map.update(acc, reg, {String.to_integer(rp), String.to_integer(rt)}, fn {ap, at} ->
                {ap + String.to_integer(rp), at + String.to_integer(rt)}
              end)
            end)

          {p + String.to_integer(bp), f + String.to_integer(bf), sk + String.to_integer(bsk), cr, regs_new}

        _ ->
          win = min(batch, total - s)
          {p, f, sk, cr + win, Map.update(regs, "crashed", {0, win}, fn {ap, at} -> {ap, at + win} end)}
      end

    done2 = done + min(batch, total - s)
    ran = p2 + f2
    pct = if ran > 0, do: Float.round(p2 * 100 / ran, 2), else: 0.0

    reglines =
      regs2
      |> Enum.sort()
      |> Enum.map(fn {reg, {rp, rt}} ->
        rpct = if rt > 0, do: Float.round(rp * 100 / rt, 1), else: 0.0
        "  #{String.pad_trailing(reg, 12)} #{rp}/#{rt} (#{rpct}%)"
      end)
      |> Enum.join("\n")

    File.write!(summary_path, """
    # FULL tc39/test262 on Porffor→Washy ASM lane (live)
    cases seen: #{done2}/#{total}   pass #{p2}/#{ran} (#{pct}%)   skip #{sk2}   crashed #{cr2}
    per top-level region:
    #{reglines}
    """)

    if rem(div(s, batch), 25) == 0 do
      IO.puts("[#{done2}/#{total}] pass #{p2}/#{ran} (#{pct}%) skip #{sk2} crashed #{cr2}")
    end

    _ = code
    {p2, f2, sk2, cr2, regs2, done2}
  end)

  IO.puts("DONE — see #{summary_path}")
end
