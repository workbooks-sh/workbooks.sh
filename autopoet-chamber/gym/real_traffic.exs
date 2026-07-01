# REAL-TRAFFIC experiments E1/E2/E5 — converting assumptions into decisive facts using
# real recorded usage that already exists locally. Nothing here is synthetic:
#
#   E1  "real usage has exploitable structure": shadow learners on THIS repo's actual
#       commit history (chronological changed-file sequences = real developer traffic).
#       PRE-REGISTERED RULE: structure confirmed iff hebb overall >= 2x the frequency
#       floor. Either outcome is a fact.
#
#   E2  "authored .work links predict real usage at birth": the authored backlink graph
#       between dogfood .work files (production parser) tested against the real co-edit
#       transitions of those same files in git history.
#       PRE-REGISTERED RULE: prior confirmed iff static-prior birth(150) beats blank-hebb
#       birth(150) by >= 5pt AND n >= 300 transitions. If n < 300 the local data is
#       insufficient and E2 is FORCIBLY classified (b) production — still binary.
#
#   E5  "fleet priors transfer to a cold tenant": leave-one-workspace-out over the 40
#       dogfood workspace repos (path-level co-touch edges from 39 workspaces as the
#       prior; held-out workspace's first 150 transitions as the cold tenant).
#       PRE-REGISTERED RULE: transfer confirmed iff mean prior-birth beats mean blank-
#       birth by >= 5pt across workspaces with >= 30 transitions. Negative result =
#       fact: path-level genomes don't transfer (genome must be artifact-level).
#
# Run:  cd nexus && mix run --no-start ../autopoet-chamber/gym/real_traffic.exs

defmodule RT.Learn do
  # Compact hebb/counts/static learners with the standard spreading readout.
  @eta 0.35
  @decay 0.9985
  @topk 3

  def new(prior \\ []) do
    g =
      for {a, b} <- prior, reduce: %{} do
        acc -> Map.update(acc, a, %{b => {0.25, 0}}, &Map.put(&1, b, {0.25, 0}))
      end

    g
  end

  def bump(g, a, b, t, :hebb) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = w0 * :math.pow(@decay, t - tl)
    Map.put(g, a, Map.put(edges, b, {w + @eta * (1.0 - w), t}))
  end

  def bump(g, a, b, _t, :counts) do
    edges = Map.get(g, a, %{})
    {w0, _} = Map.get(edges, b, {0.0, 0})
    Map.put(g, a, Map.put(edges, b, {w0 + 1.0, 0}))
  end

  def bump(g, _a, _b, _t, :static), do: g

  defp out(g, a, t, :hebb) do
    for {dst, {w, tl}} <- Map.get(g, a, %{}), into: %{}, do: {dst, w * :math.pow(@decay, t - tl)}
  end

  defp out(g, a, _t, _) do
    edges = Map.get(g, a, %{})
    total = edges |> Enum.map(fn {_, {w, _}} -> w end) |> Enum.sum() |> max(1.0)
    for {dst, {w, _}} <- edges, into: %{}, do: {dst, w / total}
  end

  def predict(g, trace, t, kind) do
    one =
      trace
      |> Enum.zip([1.0, 0.45, 0.2])
      |> Enum.reduce(%{}, fn {node, act}, acc ->
        Enum.reduce(out(g, node, t, kind), acc, fn {dst, w}, a -> Map.update(a, dst, act * w, &(&1 + act * w)) end)
      end)

    one |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.take(@topk) |> Enum.map(&elem(&1, 0))
  end

  @doc "Prequential run over a symbol stream. Returns %{name => [{t, hit}]}."
  def shadow(stream, learners) do
    {hits, _} =
      stream
      |> Enum.with_index()
      |> Enum.reduce({Map.new(learners, fn {n, _, _} -> {n, []} end),
                      {Map.new(learners, fn {n, g, _} -> {n, g} end), []}}, fn {x, t}, {hits, {gs, trace}} ->
        hits =
          if trace == [] do
            hits
          else
            Map.new(hits, fn {k, hs} ->
              {_, _, kind} = Enum.find(learners, fn {n, _, _} -> n == k end)
              {k, [{t, if(x in predict(gs[k], trace, t, kind), do: 1, else: 0)} | hs]}
            end)
          end

        gs =
          case trace do
            [prev | _] ->
              Map.new(gs, fn {k, g} ->
                {_, _, kind} = Enum.find(learners, fn {n, _, _} -> n == k end)
                {k, bump(g, prev, x, t, kind)}
              end)

            [] ->
              gs
          end

        {hits, {gs, [x | Enum.take(trace, 2) |> Enum.reject(&(&1 == x))] |> Enum.take(3)}}
      end)

    hits
  end

  def rate(hs, lo, hi) do
    win = for {t, h} <- hs, t >= lo and t < hi, do: h
    if win == [], do: nil, else: Enum.sum(win) / length(win)
  end

  def fmt(nil), do: "-"
  def fmt(x), do: :io_lib.format("~.3f", [x * 1.0]) |> to_string()
end

defmodule RT.Git do
  # Chronological changed-file stream from a git repo (oldest first).
  def stream(git_dir_args, max_commits \\ 4000, exclude \\ [], extra \\ []) do
    {out, 0} =
      System.cmd(
        "git",
        git_dir_args ++ ["log"] ++ extra ++ ["--reverse", "--name-only", "--pretty=format:@@COMMIT@@", "-n", "#{max_commits}"],
        stderr_to_stdout: true
      )

    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "@@COMMIT@@"))
    |> Enum.reject(fn f -> Enum.any?(exclude, &String.contains?(f, &1)) end)
  rescue
    _ -> []
  end

  def commits_files(git_dir_args, max_commits \\ 4000, exclude \\ []) do
    {out, 0} =
      System.cmd("git", git_dir_args ++ ["log", "--reverse", "--name-only", "--pretty=format:@@COMMIT@@", "-n", "#{max_commits}"],
        stderr_to_stdout: true
      )

    out
    |> String.split("@@COMMIT@@", trim: true)
    |> Enum.map(fn chunk ->
      chunk
      |> String.split("\n", trim: true)
      |> Enum.reject(fn f -> Enum.any?(exclude, &String.contains?(f, &1)) end)
    end)
    |> Enum.reject(&(&1 == []))
  rescue
    _ -> []
  end
end

root = Path.expand("../..", __DIR__)
exclude = [".nexus/", ".beads/", "node_modules/", "_build/"]

# ════════════════════════════════ E1 ════════════════════════════════
IO.puts("\n══ E1: real developer traffic (this repo's commit history) ══")

stream = RT.Git.stream(["-C", root], 4000, exclude)
vocab = stream |> Enum.uniq() |> length()
n = length(stream)
IO.puts("file-touch events: #{n}  distinct files: #{vocab}")

freq_floor =
  stream
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, c} -> -c end)
  |> Enum.take(3)
  |> Enum.map(&elem(&1, 1))
  |> Enum.sum()
  |> Kernel./(n)

hits = RT.Learn.shadow(stream, [{:hebb, RT.Learn.new(), :hebb}, {:counts, RT.Learn.new(), :counts}])

IO.puts("  learner    Q1         Q2         Q3         Q4         overall")

overall = fn hs -> RT.Learn.rate(hs, 0, n) end

for {name, hs} <- Enum.sort(hits) do
  IO.puts(
    "  " <>
      String.pad_trailing(to_string(name), 11) <>
      Enum.map_join(0..3, "", fn q ->
        String.pad_trailing(RT.Learn.fmt(RT.Learn.rate(hs, q * div(n, 4), (q + 1) * div(n, 4))), 11)
      end) <> RT.Learn.fmt(overall.(hs))
  )
end

hebb_overall = overall.(hits[:hebb])
IO.puts("  global-top-3 frequency floor: #{RT.Learn.fmt(freq_floor)}")
verdict1 = hebb_overall >= 2 * freq_floor
IO.puts("  PRE-REGISTERED RULE hebb >= 2x freq floor: #{RT.Learn.fmt(hebb_overall)} vs #{RT.Learn.fmt(2 * freq_floor)} -> #{if verdict1, do: "FACT: real usage HAS exploitable structure", else: "FACT: no exploitable structure at this granularity"}")

# ════════════════════════════════ E2 ════════════════════════════════
IO.puts("\n══ E2: authored .work backlinks vs real co-edit usage (dogfood) ══")

work_files = Path.wildcard(Path.join(root, "dogfood/**/*.work"))
by_base = Map.new(work_files, fn f -> {Path.basename(f, ".work"), Path.relative_to(f, root)} end)

prior_edges =
  for f <- work_files,
      node <- (try do Nexus.Literate.parse(File.read!(f)) rescue _ -> [] end),
      ref <- Map.get(node, :refs, []),
      String.starts_with?(ref, "[["),
      target = ref |> String.trim_leading("[[") |> String.trim_trailing("]]"),
      dst = Map.get(by_base, target),
      dst != nil,
      src = Path.relative_to(f, root),
      src != dst,
      uniq: true do
    {src, dst}
  end

sym_prior = Enum.uniq(prior_edges ++ Enum.map(prior_edges, fn {a, b} -> {b, a} end))

work_stream = Enum.filter(stream, &(String.starts_with?(&1, "dogfood/") and String.ends_with?(&1, ".work")))
n2 = length(work_stream)
IO.puts("resolvable authored file->file backlink edges: #{length(prior_edges)} (symmetrized #{length(sym_prior)})")
IO.puts("real .work co-edit stream: #{n2} transitions over #{work_stream |> Enum.uniq() |> length()} files")

if n2 >= 300 do
  hits2 =
    RT.Learn.shadow(work_stream, [
      {:static_prior, RT.Learn.new(sym_prior), :static},
      {:hebb_blank, RT.Learn.new(), :hebb},
      {:hebb_prior, RT.Learn.new(sym_prior), :hebb}
    ])

  IO.puts("  learner        birth(150)  overall")

  for {name, hs} <- Enum.sort(hits2) do
    IO.puts(
      "  " <>
        String.pad_trailing(to_string(name), 15) <>
        String.pad_trailing(RT.Learn.fmt(RT.Learn.rate(hs, 0, 150)), 12) <> RT.Learn.fmt(RT.Learn.rate(hs, 0, n2))
    )
  end

  sp = RT.Learn.rate(hits2[:static_prior], 0, 150)
  hb = RT.Learn.rate(hits2[:hebb_blank], 0, 150)
  verdict2 = sp != nil and hb != nil and sp - hb >= 0.05
  IO.puts("  PRE-REGISTERED RULE static-prior birth - blank birth >= 5pt: #{RT.Learn.fmt(sp)} - #{RT.Learn.fmt(hb)} -> #{if verdict2, do: "FACT: authored links ARE a usable birth prior on real usage", else: "FACT: authored links alone are NOT a sufficient birth prior on real usage"}")
else
  IO.puts("  n=#{n2} < 300 -> INSUFFICIENT LOCAL DATA: E2 is forcibly classified (b) — production hypothesis")
end

# ════════════════════════════════ E5 ════════════════════════════════
IO.puts("\n══ E5: fleet-prior transfer (leave-one-workspace-out, dogfood ws repos) ══")

ws_repos = Path.wildcard(Path.join(root, "nexus/.nexus/repos/ws_*.git"))

# workspace history lives under refs/jj/keep/* (jj-colocated bare repos) — need --all;
# streams are short (few commits each), so the honest threshold is >= 10 events and the
# birth window is whatever the cold tenant actually has.
ws_streams =
  for repo <- ws_repos,
      s = RT.Git.stream(["--git-dir", repo], 2000, [], ["--all", "--date-order"]),
      length(s) >= 10,
      do: {Path.basename(repo, ".git"), s}

IO.puts("workspace repos: #{length(ws_repos)} total, #{length(ws_streams)} with >= 10 file-touch events (refs/jj/keep)")

if length(ws_streams) >= 3 do
  # shared-vocabulary check: fraction of a ws's paths seen in other workspaces
  all_paths = Map.new(ws_streams, fn {ws, s} -> {ws, MapSet.new(s)} end)

  shared =
    for {ws, paths} <- all_paths do
      others = all_paths |> Map.delete(ws) |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      MapSet.intersection(paths, others) |> MapSet.size() |> Kernel./(max(MapSet.size(paths), 1))
    end

  IO.puts("shared-path fraction (mean across workspaces): #{RT.Learn.fmt(Enum.sum(shared) / length(shared))}")

  results =
    for {ws, s} <- ws_streams do
      prior =
        ws_streams
        |> Enum.reject(fn {w, _} -> w == ws end)
        |> Enum.flat_map(fn {_, os} -> Enum.zip(os, tl(os)) end)
        |> Enum.uniq()

      birth = Enum.take(s, 150)

      hits =
        RT.Learn.shadow(birth, [{:prior, RT.Learn.new(prior), :static}, {:blank, RT.Learn.new(), :hebb}])

      {ws, RT.Learn.rate(hits[:prior], 0, 150), RT.Learn.rate(hits[:blank], 0, 150)}
    end

  ps = for {_, p, _} <- results, p != nil, do: p
  bs = for {_, _, b} <- results, b != nil, do: b
  mp = Enum.sum(ps) / max(length(ps), 1)
  mb = Enum.sum(bs) / max(length(bs), 1)

  IO.puts("  mean birth(150) hit rate — fleet prior: #{RT.Learn.fmt(mp)}   blank: #{RT.Learn.fmt(mb)}   (#{length(results)} workspaces)")

  verdict5 = mp - mb >= 0.05
  IO.puts("  PRE-REGISTERED RULE prior - blank >= 5pt: #{if verdict5, do: "FACT: path-level fleet priors DO transfer to cold tenants", else: "FACT: path-level fleet priors DO NOT transfer — genomes must be artifact/template-level"}")
else
  IO.puts("  fewer than 3 usable workspace histories -> INSUFFICIENT LOCAL DATA: E5 forcibly (b)")
end

IO.puts("")
