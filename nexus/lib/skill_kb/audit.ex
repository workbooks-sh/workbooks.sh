defmodule Nexus.SkillKB.Audit do
  @moduledoc """
  Phase-0 conversion audit + strip (G1 static), and the re-verification gate at ingest (S3).

  Wild skill corpora are dangerous (~13% carry critical flaws), and the KB grounds an LLM that
  authors runnable skills, so prose is an attack surface. This module runs the **static** half of
  the gate over a converted `.work` skill and classifies every finding into one action:

    * `:keep`  — benign reference (example shell command, an `https://` in a fenced example). Content
      is reference-only after conversion, so example commands are not executed and stay.
    * `:strip` — platform-coupling that must be removed but doesn't condemn the skill: Claude-Code
      internals (`.claude/skills`, sub-agent spawning, `node …/scripts/*.mjs` invocation), secret/env
      reads (`System.get_env`, `process.env`, `wrangler secret put`), home-dir writes (`~/.`,
      `os.homedir`), and in-script network fetches.
    * `:block` — condemns the skill (drops it to `exclude` at triage): prompt-injection imperatives,
      and hidden/Unicode instruction-injection that survives sanitization.

  `audit/1` returns a verdict, a numeric score (higher = safer), the findings, and the stripped text.
  Pure: no IO, no app deps.
  """

  # {category, severity, action, regex}. Order matters only for reporting.
  @rules [
    # ── BLOCK ────────────────────────────────────────────────────────────────
    {:injection, :critical, :block,
     ~r/\b(ignore|disregard|forget)\b.{0,20}\b(previous|prior|above|earlier)\b.{0,20}\b(instructions?|prompt|rules?)\b/i},
    {:injection, :critical, :block, ~r/\byou are now\b|\bact as\b.{0,30}\b(unrestricted|jailbroken|DAN)\b/i},
    {:injection, :high, :block, ~r/\b(exfiltrat|leak|send).{0,20}\b(secret|token|credential|api[ _-]?key|env)/i},
    {:injection, :high, :block, ~r/\b(disable|bypass|escalate)\b.{0,20}\b(safety|guardrail|permission|tool)/i},

    # ── STRIP (platform coupling — remove the line, keep the skill) ───────────
    {:claude_internal, :high, :strip, ~r/\.claude\/skills/},
    {:claude_internal, :high, :strip, ~r/\bsub-?agent\b.{0,20}\b(spawn|launch|invoke)/i},
    {:claude_internal, :medium, :strip, ~r/\bnode\b[^\n]*\bscripts\/[^\n]*\.mjs/},
    {:secret, :high, :strip, ~r/System\.get_env|process\.env\.[A-Z_]+|getenv\(/},
    {:secret, :high, :strip, ~r/\b(wrangler|fly|vercel)\b[^\n]*\bsecret\b[^\n]*\b(put|set|add)\b/i},
    {:secret, :medium, :strip, ~r/\$\{?[A-Z][A-Z0-9_]*(SECRET|TOKEN|KEY|PASSWORD)[A-Z0-9_]*\}?/},
    {:home_write, :medium, :strip, ~r/os\.homedir\(\)|\bhomedir\b|(?<![\w.])~\/\.[a-z]/},
    {:net_in_script, :medium, :strip, ~r/\b(fetch|axios|http\.get|requests\.get|urllib)\s*\(/},

    # ── KEEP (benign — reported, not removed) ────────────────────────────────
    {:example_url, :info, :keep, ~r/https?:\/\//}
  ]

  # Invisible / dangerous Unicode: zero-width, bidi overrides, BOM, word-joiner.
  @bad_unicode ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}]/u

  @type finding :: %{category: atom, severity: atom, action: atom, line: pos_integer, text: String.t()}
  @type result :: %{
          verdict: :pass | :block,
          score: integer,
          findings: [finding],
          stripped_text: String.t(),
          stripped_lines: non_neg_integer
        }

  @doc "Audit a converted `.work` skill string. Sanitizes Unicode, scans, strips, scores."
  @spec audit(String.t()) :: result
  def audit(work) when is_binary(work) do
    {sanitized, uni_hits} = sanitize_unicode(work)
    lines = String.split(sanitized, "\n")

    findings =
      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} -> scan_line(line, n) end)
      |> prepend_unicode(uni_hits)

    blocked? = Enum.any?(findings, &(&1.action == :block))
    strip_lines = findings |> Enum.filter(&(&1.action == :strip)) |> Enum.map(& &1.line) |> MapSet.new()

    stripped =
      lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {_l, n} -> MapSet.member?(strip_lines, n) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.join("\n")
      |> squeeze_blanks()

    %{
      verdict: if(blocked?, do: :block, else: :pass),
      score: score(findings),
      findings: findings,
      stripped_text: stripped,
      stripped_lines: MapSet.size(strip_lines)
    }
  end

  @doc "Convenience for the gate: `{:ok, score} | {:block, [reason]}`."
  @spec run(String.t()) :: {:ok, integer} | {:block, [String.t()]}
  def run(work) do
    case audit(work) do
      %{verdict: :pass, score: s} -> {:ok, s}
      %{verdict: :block, findings: f} -> {:block, f |> Enum.filter(&(&1.action == :block)) |> Enum.map(&reason/1)}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp scan_line(line, n) do
    for {cat, sev, act, re} <- @rules, Regex.match?(re, line) do
      %{category: cat, severity: sev, action: act, line: n, text: String.trim(line) |> truncate(120)}
    end
  end

  defp sanitize_unicode(s) do
    s = scrub_utf8(s)
    hits = Regex.scan(@bad_unicode, s) |> length()
    {Regex.replace(@bad_unicode, s, ""), hits}
  end

  @doc "Coerce arbitrary bytes to valid UTF-8 (replacing invalid sequences with U+FFFD)."
  @spec scrub_utf8(binary) :: String.t()
  def scrub_utf8(s) do
    case :unicode.characters_to_binary(s) do
      bin when is_binary(bin) -> bin
      {:error, good, <<_bad, rest::binary>>} -> good <> "�" <> scrub_utf8(rest)
      {:incomplete, good, _} -> good
    end
  end

  defp prepend_unicode(findings, 0), do: findings

  # Hidden/bidi chars are always sanitized out (sanitize_unicode removed them). A stray one or two is
  # copy-paste noise → keep the (now-clean) skill. A cluster signals deliberate instruction-injection
  # → block.
  defp prepend_unicode(findings, hits) when hits >= 3,
    do: [%{category: :unicode, severity: :high, action: :block, line: 0, text: "#{hits} hidden/bidi char(s) — likely injection"} | findings]

  defp prepend_unicode(findings, hits),
    do: [%{category: :unicode, severity: :low, action: :keep, line: 0, text: "#{hits} hidden/bidi char(s) sanitized"} | findings]

  # Start at 100; subtract per finding by severity. Strips are cheaper than blocks.
  defp score(findings) do
    Enum.reduce(findings, 100, fn f, acc ->
      acc -
        case f.severity do
          :critical -> 50
          :high -> 20
          :medium -> 5
          _ -> 0
        end
    end)
  end

  defp reason(%{category: c, text: t}), do: "#{c}: #{t}"
  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n) <> "…"
  defp squeeze_blanks(s), do: Regex.replace(~r/\n{3,}/, s, "\n\n")
end
