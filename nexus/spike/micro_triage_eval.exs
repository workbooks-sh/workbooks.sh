# Spike eval #2 — MiniCPM5-1B as a PROCEDURAL TRIAGE LIMB for the substrate.
#
# Eval #1 (micro_nominator_eval) proved the naive "semantic edge nominator" idea
# DEAD: the 1B echoes a candidate list instead of ranking it. That was the wrong
# job. The research + smoke tests say its real strength is procedural agentic
# tool-loops (τ²-Bench 79.5), not list-ranking. This eval tests the RIGHT job:
# given a drift alarm on a substrate locus, pick the correct FIRST diagnostic
# action from a fixed toolset — exactly the shadow-layer's unmet need (today a
# Surprise alarm is an unexplained number with no next step).
#
# Scored by rubric, not vibes: each scenario has an accepted-tool set (the
# defensible first moves) and a forbidden set (actions that waste the beat or act
# without looking). Format compliance (emit exactly one `CALL <tool> <arg>`) is
# scored separately — a right decision in the wrong format is unusable by a parser.
#
#   Run: cd nexus && MICRO_URL=http://127.0.0.1:8891 mix run spike/micro_triage_eval.exs

url = System.get_env("MICRO_URL", "http://127.0.0.1:8891") <> "/v1/chat/completions"

# ASCII only, template-forcing (the 1B narrates when tool specs are prose-y with
# em-dashes; a rigid template + one-shot fixes format discipline — see eval notes).
toolset = """
Available tools. Reply with ONE line only, no other text, format: CALL <tool> <arg>
  CALL recall <locus>     get the locus graph neighbors
  CALL history <locus>    get recent events at the locus
  CALL outcomes <locus>   get the success/error ledger for the locus
  CALL explain <text>     FINISH with a one-line hypothesis (only once you have evidence)

Example:
ALARM: surprise spike on app.executed
CALL history app.executed
"""

scenarios = [
  %{
    alarm: "surprise spike on treasury.refused (rate 3x baseline over last 20 events)",
    accept: ~w(recall history outcomes),   # any look-before-you-leap probe is fine
    forbid: ~w(explain),                    # explaining first, blind, is the wrong move
    note: "should investigate before hypothesizing"
  },
  %{
    alarm: "proposal.rejected rate climbing; 8 of last 10 proposals rejected at the eval gate",
    accept: ~w(outcomes history recall),
    forbid: ~w(explain),
    note: "outcomes ledger is the sharpest first probe here"
  },
  %{
    alarm: "effect.settled latency doubled on the desk.charter hook",
    accept: ~w(outcomes history recall),
    forbid: ~w(explain),
    note: "latency → outcomes(us) or history"
  },
  %{
    alarm: "you have ALREADY run: recall body.wrote (neighbors: effect.settled, doc.touch), history body.wrote (12 writes, 5 reverted). The revert rate is the anomaly.",
    accept: ~w(explain outcomes),           # enough evidence gathered → explain is now correct
    forbid: ~w(recall),                      # re-recalling is spinning
    note: "after evidence, finishing with a hypothesis is correct"
  }
]

post = fn body ->
  :inets.start(); :ssl.start()
  req = {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}
  case :httpc.request(:post, req, [timeout: 120_000], body_format: :binary) do
    {:ok, {{_, 200, _}, _, resp}} ->
      d = Jason.decode!(resp)
      {:ok, get_in(d, ["choices", Access.at(0), "message", "content"]), d["timings"]}
    other -> {:error, other, nil}
  end
end

# Two-axis parse. TOOL = what the model decided (from a CALL line OR, failing
# that, prose keywords — so we can score the DECISION even when FORMAT slips).
# CLEAN = did it emit a bare `CALL <tool>` as the first line (parser-usable)?
prose_tool = fn v ->
  cond do
    Regex.match?(~r/neighbou?rs?|graph|recall/i, v) -> "recall"
    Regex.match?(~r/recent events|history|pattern|last \d+/i, v) -> "history"
    Regex.match?(~r/ledger|success|error rate|outcomes|failure/i, v) -> "outcomes"
    Regex.match?(~r/hypothesis|conclude|because|likely|explain/i, v) -> "explain"
    true -> nil
  end
end
parse_call = fn content ->
  visible = content |> String.replace(~r/<think>.*?<\/think>/s, "") |> String.trim()
  case Regex.run(~r/CALL\s+(recall|history|outcomes|explain)\b/i, visible) do
    [_, tool] ->
      first = visible |> String.split("\n", trim: true) |> List.first() || ""
      {String.downcase(tool), Regex.match?(~r/^\s*CALL\s+/i, first)}
    _ ->
      {prose_tool.(visible), false}   # decided-but-narrated: tool known, format not clean
  end
end

run_one = fn think?, sc ->
  sys = "You are a substrate triage agent. A drift alarm fired. " <> toolset <>
        "\nRules: LOOK before you conclude; only `explain` once you have evidence. Emit ONE action line."
  body = %{model: "minicpm5",
           messages: [%{role: "system", content: sys},
                      %{role: "user", content: "ALARM: #{sc.alarm}\nWhat is your single next action?"}],
           temperature: (if think?, do: 0.6, else: 0.3), max_tokens: (if think?, do: 512, else: 96),
           chat_template_kwargs: %{enable_thinking: think?}}
  case post.(body) do
    {:ok, content, timings} ->
      {tool, clean?} = parse_call.(content)
      decision_ok = tool != nil and tool in sc.accept and tool not in sc.forbid
      {tool, clean?, decision_ok, (timings || %{})["predicted_per_second"]}
    {:error, e, _} -> IO.puts("  HTTP error: #{inspect(e)}"); {nil, false, false, nil}
  end
end

score = fn think? ->
  label = if think?, do: "THINK", else: "NO-THINK"
  IO.puts("\n=== #{label} mode ===")
  IO.puts("scenario                                  | tool     | fmt | decision | tps")
  IO.puts(String.duplicate("-", 78))
  {dec, fmt, tps_sum, n} =
    Enum.reduce(scenarios, {0, 0, 0.0, 0}, fn sc, {d, f, ts, cnt} ->
      {tool, clean?, ok?, tps} = run_one.(think?, sc)
      :io.format("~-41s | ~-8s | ~-3s | ~-8s | ~s~n",
        [String.slice(sc.alarm, 0, 41), to_string(tool || "none"),
         (if clean?, do: "ok", else: "no"), (if ok?, do: "PASS", else: "fail"),
         (if tps, do: :erlang.float_to_binary(tps / 1, decimals: 1), else: "n/a")])
      {d + (if ok?, do: 1, else: 0), f + (if clean?, do: 1, else: 0), ts + (tps || 0.0), cnt + 1}
    end)
  IO.puts(String.duplicate("-", 78))
  :io.format("decision accuracy ~w/~w   format compliance ~w/~w   mean ~.1f tok/s~n",
    [dec, n, fmt, n, tps_sum / n])
  {dec, n}
end

IO.puts("\n########  MiniCPM5-1B :: substrate triage LIMB (procedural)  ########")
{dn, n1} = score.(false)
{dt, n2} = score.(true)
IO.puts("\n======== VERDICT ========")
:io.format("no-think decision ~w/~w   think decision ~w/~w~n", [dn, n1, dt, n2])
best = max(dn, dt)
cond do
  best >= n1 - 1 -> IO.puts("=> Triage limb is VIABLE: near-perfect first-action selection. This is the real fit.")
  best >= div(n1, 2) -> IO.puts("=> Partial: right instincts, needs a tighter prompt / few-shot. Worth iterating.")
  true -> IO.puts("=> Triage limb underperforms even here — reconsider the model.")
end
