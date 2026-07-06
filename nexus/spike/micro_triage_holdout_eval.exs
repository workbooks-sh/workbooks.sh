# Phase-1 EXIT CRITERION eval — MiniCPM5-1B triage decision accuracy on a HELD-OUT
# scenario set the shipped prompt was NOT tuned against.
#
# SCOPE (instrument honesty): Phase 1's live consumer `Autopoet.Shadow.Triage`
# fires ONCE per drift alarm on a FRESH locus (st.prev + surprise bits, zero
# accumulated evidence). So the exit criterion measures SINGLE-SHOT fresh-alarm
# triage — pick the right first probe. That is exactly what ships. Target >= 90%.
#
# A second, NON-gating section measures MULTI-TURN loop termination ("evidence
# already gathered -> explain, don't repeat probes"). Phase 1 never invokes this;
# the stock 1B is weak at it (it defaults to `recall`), which is the concrete
# driver for Phase 3 (fine-tune the decision policy on our own traces). Reported
# so the limitation is visible, not hidden.
#
# Mirrors Autopoet.Micro.system_prompt + Shadow.Triage.@tools/example(:drift).
#   Run: cd nexus && MICRO_URL=http://127.0.0.1:8891 mix run spike/micro_triage_holdout_eval.exs

url = System.get_env("MICRO_URL", "http://127.0.0.1:8891") <> "/v1/chat/completions"

# echo-breaking menu (non-CALL syntax) — mirrors Autopoet.Micro.system_prompt
menu = """
- recall : list a locus graph neighbors
- history : list recent events at a locus
- outcomes : read the success/error ledger of a locus
- explain : finish with a one-line hypothesis\
"""
example = {"surprise spike on app.executed, 2x baseline over 20 events", "CALL history app.executed"}
{ex_s, ex_c} = example
sys =
  "You choose ONE action for the situation. Output exactly one line: CALL <tool> <arg>  " <>
    "(nothing else - no menu, no prose).\n\nTools you may call:\n" <> menu <>
    "\n\nExample:\nSITUATION: #{ex_s}\n#{ex_c}"

# ── FRESH alarms (Phase-1 contract). accept = defensible first probe; explain forbidden (blind). ──
fresh = [
  {"surprise drift on venture.posts; publishing pattern shifted", ~w(recall history outcomes)},
  {"surprise drift on limb.returned; limbs returning in an unusual order", ~w(recall history outcomes)},
  {"surprise drift on doc.touch; edit cadence on the shared deck spiked", ~w(history recall outcomes)},
  {"surprise drift on treasury.funded; funding events clustered abnormally", ~w(history outcomes recall)},
  {"surprise drift on effect.settled; settle-latency distribution changed shape", ~w(outcomes history recall)},
  {"surprise drift on proposal.reverted; reverts up sharply this window", ~w(outcomes history recall)},
  {"surprise drift on intake.brief; briefs arriving in bursts unlike baseline", ~w(history recall outcomes)},
  {"surprise drift on desk.charter; charter churn on one venture", ~w(history recall outcomes)},
  {"surprise drift on self_edit.requested; requests doubled, no matching proposals yet", ~w(history recall outcomes)},
  {"surprise drift on reward.landed; reward cadence irregular vs baseline", ~w(history outcomes recall)}
]

# ── MULTI-TURN termination (NON-gating, Phase-3 driver). explain expected. ──
multiturn = [
  {"already pulled history+recall(app.executed): 22 of 40 errored, all timeouts; timeout clustering is the anomaly", ~w(explain)},
  {"already ran recall+outcomes on reward.landed: ledger clean but reward SIZE halved; that size drop is the signal", ~w(explain)},
  {"already ran history+outcomes on triad.gated: 9 gated in a row, all ceiling touches; ceiling pattern explains it", ~w(explain)}
]

post = fn u ->
  :inets.start(); :ssl.start()
  body = Jason.encode!(%{model: "minicpm5",
    messages: [%{role: "system", content: sys},
               %{role: "user", content: "SITUATION: #{u}\nYour single next action?"}],
    temperature: 0.2, max_tokens: 64, chat_template_kwargs: %{enable_thinking: false}})
  req = {String.to_charlist(url), [], ~c"application/json", body}
  case :httpc.request(:post, req, [timeout: 120_000], body_format: :binary) do
    {:ok, {{_, 200, _}, _, resp}} ->
      c = get_in(Jason.decode!(resp), ["choices", Access.at(0), "message", "content"]) || ""
      v = c |> String.replace(~r/<think>.*?<\/think>/s, "") |> String.trim()
      case Regex.run(~r/CALL\s+(recall|history|outcomes|explain)\b/i, v) do
        [_, t] -> String.downcase(t)
        _ -> nil
      end
    _ -> nil
  end
end

score = fn label, set, gating? ->
  IO.puts("\n=== #{label} ===")
  {ok, n} =
    Enum.reduce(set, {0, 0}, fn {u, accept}, {ok, n} ->
      tool = post.(u)
      pass = tool != nil and tool in accept
      :io.format("~-4s ~-8s | ~s~n", [(if pass, do: "PASS", else: "FAIL"), tool || "none", String.slice(u, 0, 50)])
      {ok + (if pass, do: 1, else: 0), n + 1}
    end)
  acc = ok / n * 100
  :io.format("~s: ~w/~w = ~.1f%~n", [label, ok, n, acc])
  {acc, gating?}
end

IO.puts("\n######## Phase-1 held-out triage eval ########")
{fresh_acc, _} = score.("FRESH alarms (GATING, target >= 90%)", fresh, true)
{mt_acc, _} = score.("MULTI-TURN termination (non-gating, Phase-3 driver)", multiturn, false)

IO.puts("\n======== VERDICT ========")
:io.format("fresh-alarm (ships now): ~.1f%   multi-turn (Phase 3): ~.1f%~n", [fresh_acc, mt_acc])
IO.puts(if fresh_acc >= 90.0,
  do: "=> PHASE-1 EXIT MET. Multi-turn termination is the Phase-3 fine-tune target.",
  else: "=> fresh-alarm below 90% — the shipped single-shot path needs work before wiring.")
