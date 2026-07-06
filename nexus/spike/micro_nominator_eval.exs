# Spike eval — MiniCPM5-1B vs the shipped Hashed-embed baseline as a SEMANTIC
# NOMINATOR for the autopoet substrate genome (`Autopoet.Genome.semantic_edges`
# canon: "embeddings NOMINATE, counts ELECT"). Load-bearing question: does a
# resident 1B micro-model nominate BETTER edges than the zero-dep hashed-trigram
# embedder we ship today?
#
# Instrument honesty (diagnostics §0) — this eval was WRONG on its first pass and
# the fix is the point:
#   * v1 gold clustered loci by LEXICAL PREFIX (treasury.*, body.*). Character-
#     trigram hashing wins that by string overlap — it measures spelling, not
#     meaning. Hashed scored a fake 1.000.
#   * The real substrate need is CROSS-PREFIX CAUSAL relatedness: the chain
#     proposal.accepted → body.wrote → effect.settled → reward.landed →
#     treasury.earned shares ZERO trigrams, so hashing is blind to it. THAT is
#     where a 1B that understands the domain can actually add signal.
# So we score BOTH gold sets and report them separately — the lexical set is the
# hashed embedder's home turf; the causal set is the honest test.
#
#   Run: cd nexus && MICRO_URL=http://127.0.0.1:8891 mix run spike/micro_nominator_eval.exs
#
# Exit criterion: MiniCPM5 must clearly beat Hashed on the CAUSAL set (its reason
# to exist). Losing the lexical set is fine — that's not what it's for.

url = System.get_env("MICRO_URL", "http://127.0.0.1:8891") <> "/v1/chat/completions"
debug? = System.get_env("MICRO_DEBUG") == "1"

pool =
  ~w(treasury.charged treasury.refused treasury.earned treasury.funded reward.landed
     proposal.recorded proposal.accepted proposal.rejected proposal.reverted triad.gated
     body.wrote body.undone body.redone doc.touch effect.settled
     venture.charter venture.identity venture.posts desk.charter intake.brief
     limb.returned app.executed self_edit.requested autopoet.attention recall.ab)

# LEXICAL gold — same-prefix siblings. Hashed's home turf (sanity check only).
lexical = %{
  "treasury.charged" => ~w(treasury.refused treasury.earned treasury.funded),
  "proposal.recorded" => ~w(proposal.accepted proposal.rejected proposal.reverted),
  "body.wrote" => ~w(body.undone body.redone doc.touch),
  "venture.charter" => ~w(venture.identity venture.posts desk.charter)
}

# CAUSAL gold — cross-prefix consequence chains, zero shared trigrams. The honest
# test: only a model that knows the substrate's DYNAMICS can surface these.
causal = %{
  # a proposal accepted causes a body write, which settles an effect and lands reward
  "proposal.accepted" => ~w(body.wrote effect.settled reward.landed treasury.earned),
  # a limb returns → app executes → effect settles → treasury is charged for the work
  "limb.returned" => ~w(app.executed effect.settled treasury.charged reward.landed),
  # a self-edit request drives autopoet attention → a proposal is recorded → gated
  "self_edit.requested" => ~w(autopoet.attention proposal.recorded triad.gated body.wrote),
  # an intake brief personalizes a venture identity and seeds its posts
  "intake.brief" => ~w(venture.identity venture.charter venture.posts desk.charter)
}

hashed = fn text -> Nexus.Embed.Hashed.embed([text]) |> List.first() end
embed_rank = fn source, cands ->
  sv = hashed.(source)
  cands
  |> Enum.map(fn c -> {c, Nexus.Embed.cosine(sv, hashed.(c))} end)
  |> Enum.sort_by(fn {_, s} -> -s end)
  |> Enum.map(&elem(&1, 0))
end

post = fn body ->
  :inets.start(); :ssl.start()
  req = {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}
  case :httpc.request(:post, req, [timeout: 120_000], body_format: :binary) do
    {:ok, {{_, 200, _}, _, resp}} ->
      %{"choices" => [%{"message" => %{"content" => c}} | _]} = Jason.decode!(resp)
      {:ok, c}
    other -> {:error, other}
  end
end

# Robust parse: pull any pool token out of each line, in order. Never silently
# empties (the v1 bug) — an unparseable line just contributes nothing.
parse_ranking = fn content, cands ->
  content
  |> String.split(~r/[\n,]/, trim: true)
  |> Enum.flat_map(fn line ->
    Regex.scan(~r/[a-z_]+\.[a-z_.]+/, line) |> Enum.map(&List.first/1)
  end)
  |> Enum.filter(&(&1 in cands))
  |> Enum.uniq()
end

model_rank = fn source, cands ->
  sys = "You rank graph event-loci by CAUSAL/semantic relatedness to a source locus " <>
        "(what tends to happen right before/after it in the system). Output ONLY candidate " <>
        "names, most-related first, one per line. No scores, no prose, no source echo."
  usr = "Source: #{source}\nCandidates:\n" <> Enum.map_join(cands, "\n", &("- " <> &1))
  body = %{model: "minicpm5",
           messages: [%{role: "system", content: sys}, %{role: "user", content: usr}],
           temperature: 0.2, max_tokens: 256, chat_template_kwargs: %{enable_thinking: false}}
  case post.(body) do
    {:ok, content} ->
      ranked = parse_ranking.(content, cands)
      if debug?, do: IO.puts("  [#{source}] parsed #{length(ranked)}/#{length(cands)}: #{Enum.take(ranked, 5) |> Enum.join(", ")}")
      # tail-fill so P@k is defined; parse-failure is visible as a short `ranked`
      ranked ++ (cands -- ranked)
    {:error, e} -> IO.puts("  [#{source}] HTTP error: #{inspect(e)}"); cands
  end
end

p_at = fn ranked, gold, k ->
  (ranked |> Enum.take(k) |> Enum.count(&(&1 in gold))) / min(k, length(gold))
end

run = fn label, golds ->
  IO.puts("\n=== #{label} ===")
  IO.puts("source                | P@3 hashed | P@3 model | winner")
  IO.puts(String.duplicate("-", 60))
  {sh, sm, n} =
    Enum.reduce(golds, {0.0, 0.0, 0}, fn {source, gold}, {sh, sm, cnt} ->
      cands = pool -- [source]
      ph = p_at.(embed_rank.(source, cands), gold, 3)
      pm = p_at.(model_rank.(source, cands), gold, 3)
      win = cond do pm > ph -> "MODEL"; pm < ph -> "hashed"; true -> "tie" end
      :io.format("~-21s | ~-10.3f | ~-9.3f | ~s~n", [source, ph, pm, win])
      {sh + ph, sm + pm, cnt + 1}
    end)
  :io.format("~-21s | ~-10.3f | ~-9.3f |~n", ["MEAN", sh / n, sm / n])
  {sh / n, sm / n}
end

IO.puts("\n########  MiniCPM5-1B vs Hashed-embed :: substrate nominator  ########")
{lh, lm} = run.("LEXICAL gold (hashed's home turf — sanity)", lexical)
{ch, cm} = run.("CAUSAL gold (the honest test — cross-prefix dynamics)", causal)

IO.puts("\n======== VERDICT ========")
:io.format("lexical:  hashed=~.3f  model=~.3f~n", [lh, lm])
:io.format("causal :  hashed=~.3f  model=~.3f   <-- the one that matters~n", [ch, cm])
cond do
  cm > ch + 0.15 -> IO.puts("=> MODEL earns the nominator slot: it sees causal structure hashing is blind to.")
  cm > ch -> IO.puts("=> Model edges ahead on causal; margin thin — weigh 1.3GB RSS vs the gain.")
  true -> IO.puts("=> Model does NOT beat hashed even on causal turf. Keep the zero-dep embedder.")
end
