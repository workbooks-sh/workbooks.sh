defmodule Nexus.Autopoet.Knowledge do
  @moduledoc """
  The autopoet's continual-learning store (Autopoiesis v2 — wb-a6u3.13). The autopoet writes lessons
  here FREELY — accumulated patterns, gotchas, rules-to-apply-across-the-nexus — and reads them back to
  inform the edits it makes. This is the Karpathy-style learning surface, and it is the one thing the
  autopoet is allowed to mutate without a human: **learning is DATA**, distinct from its own structure
  (definition/grants/ceiling), which stays frozen and human-gated.

  Storage is a durable, append-only `.work` file under the persistent volume — NO JSON, one lesson per
  line (`- (topic) lesson :: evidence`), human-readable, the lines ARE the source of truth. Identical
  lessons are not re-appended.
  """

  @doc "The knowledge file path (under the durable volume, override `dir` for tests)."
  def path(dir \\ default_dir()), do: Path.join(dir, "knowledge.work")

  @doc "Record a lesson under `topic`. Idempotent — an identical lesson is not appended twice."
  def learn(topic, lesson, evidence \\ nil, dir \\ default_dir()) do
    entry = format(to_string(topic), to_string(lesson), evidence)
    p = path(dir)
    File.mkdir_p!(Path.dirname(p))

    existing = if File.exists?(p), do: File.read!(p), else: header()

    # Idempotent: an identical lesson line is never appended twice.
    unless String.contains?(existing, entry <> "\n") do
      File.write!(p, ensure_nl(existing) <> entry <> "\n")
    end

    :ok
  end

  @doc "Recall lessons, optionally filtered to a `topic`. Most-recent last (append order)."
  def recall(topic \\ nil, dir \\ default_dir()) do
    case File.read(path(dir)) do
      {:ok, body} -> body |> parse() |> filter_topic(topic)
      _ -> []
    end
  end

  @doc "How many lessons are stored."
  def count(dir \\ default_dir()), do: recall(nil, dir) |> length()

  # ── format / parse ──

  defp format(topic, lesson, nil), do: "- (#{topic}) #{collapse(lesson)}"
  defp format(topic, lesson, evidence), do: "- (#{topic}) #{collapse(lesson)} :: #{collapse(to_string(evidence))}"

  @entry ~r/^- \((?<topic>[^)]+)\) (?<lesson>.+?)(?: :: (?<evidence>.+))?$/

  defp parse(body) do
    body
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.named_captures(@entry, String.trim(line)) do
        %{"topic" => t, "lesson" => l, "evidence" => e} ->
          [%{topic: t, lesson: l, evidence: (if e == "", do: nil, else: e)}]

        _ ->
          []
      end
    end)
  end

  defp filter_topic(lessons, nil), do: lessons
  defp filter_topic(lessons, topic), do: Enum.filter(lessons, &(&1.topic == to_string(topic)))

  defp header, do: "# Autopoet knowledge\n\nLessons the autopoet has learned (append-only; the lines are the source of truth).\n\n"
  defp ensure_nl(s), do: if(String.ends_with?(s, "\n"), do: s, else: s <> "\n")
  defp collapse(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()
  defp default_dir, do: Path.join(Nexus.Paths.durable_dir(), "autopoet")
end
