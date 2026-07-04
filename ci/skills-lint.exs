# ci/skills-lint.exs — the skills anti-drift gate + coverage dashboard.
#
# Canonical, self-contained (no deps, no nexus compile) so CI runs it in seconds. Run:
#     elixir ci/skills-lint.exs
# (`mix skills.lint` is a thin wrapper over this.) Exits non-zero on drift of a GATED surface.
#
# For each SURFACE an agent can touch it extracts the ground truth straight from source and measures how
# much skills/ covers. Verbs are a hard GATE (drift = CI red); routes/blocks/env are a coverage dashboard.

defmodule SkillsLint do
  def run do
    root = Path.expand("..", __DIR__)
    body = skills_body(root)

    surfaces = [
      %{kind: :gate, name: "work CLI verbs", truth: cli_verbs(root), doc: &verb_doc?/2, exempt: ~w(help version)},
      # the autopoet cage: triad fields + grantable caps, straight from nexus source —
      # the internal/ brain-authoring skill must name every one (born gated)
      %{kind: :gate, name: "agent triad + caps", truth: agent_surface(root), doc: &word_doc?/2, exempt: []},
      %{kind: :dash, name: "API routes", truth: api_routes(root), doc: &substr_doc?/2, exempt: []},
      %{kind: :dash, name: ".work block kinds", truth: work_blocks(root), doc: &word_doc?/2, exempt: []},
      %{kind: :dash, name: "config/env knobs", truth: env_knobs(root), doc: &substr_doc?/2, exempt: []}
    ]

    IO.puts("skills.lint · agent-facing surface coverage (source of truth → skills/)")

    drift? =
      Enum.reduce(surfaces, false, fn s, acc ->
        truth = MapSet.difference(s.truth, MapSet.new(s.exempt))
        uncovered = truth |> Enum.reject(&s.doc.(body, &1)) |> MapSet.new()
        total = MapSet.size(truth)
        gate = if s.kind == :gate, do: " [GATE]", else: ""
        IO.puts("  #{String.pad_trailing(s.name, 18)} #{total - MapSet.size(uncovered)}/#{total}#{gate}")

        if MapSet.size(uncovered) > 0 do
          tag = if s.kind == :gate, do: "DRIFT", else: "gap"
          IO.puts("      #{tag}: #{preview(uncovered)}")
        end

        acc or (s.kind == :gate and MapSet.size(uncovered) > 0)
      end)

    if drift? do
      IO.puts("✗ drift on a GATED surface — update skills/ (or the code) before merge")
      System.halt(1)
    else
      IO.puts("✓ no drift on gated surfaces")
    end
  end

  defp cli_verbs(root), do: scan(Path.join([root, "cli", "src", "main.zig"]), ~r/eql\(verb, "([a-z]+)"\)/)

  # The agent-cage vocabulary an agent brain must know: the structural triad
  # (nexus/lib/agent.ex @structural_triad) + every grantable capability
  # (nexus/lib/capabilities.ex @grantable). Skills naming a fake cap would be
  # trusted prose about untrusted power — gate it.
  defp agent_surface(root) do
    triad = scan_sigil(Path.join(root, "nexus/lib/agent.ex"), ~r/@structural_triad\s+~w\(([^)]+)\)/)
    caps = scan_sigil(Path.join(root, "nexus/lib/capabilities.ex"), ~r/@grantable\s+~w\(([^)]+)\)/)
    MapSet.union(triad, caps)
  end

  defp scan_sigil(path, rx) do
    if File.exists?(path) do
      case Regex.run(rx, File.read!(path)) do
        [_, words] -> words |> String.split() |> MapSet.new()
        _ -> MapSet.new()
      end
    else
      MapSet.new()
    end
  end

  defp api_routes(root) do
    ~w(nexus/lib/platform.ex nexus/lib/cloud/api.ex)
    |> Enum.flat_map(&scan_list(Path.join(root, &1), ~r/\b(?:get|post|put|delete)\s+"(\/[^"]*)"/))
    |> Enum.map(&Regex.replace(~r/\/:[a-z_]+/, &1, ""))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp work_blocks(root) do
    (Path.wildcard(Path.join(root, "dogfood/**/*.work")) ++ Path.wildcard(Path.join(root, "toolkits/**/*.work")))
    |> Enum.flat_map(fn f ->
      Regex.scan(~r/^([a-z][a-z_]*)(?:\s+[a-z]+)?\s+:[a-z_]+.*\sdo\s*$/m, File.read!(f)) |> Enum.map(fn [_, k] -> k end)
    end)
    |> MapSet.new()
  end

  defp env_knobs(root) do
    Path.wildcard(Path.join(root, "nexus/lib/**/*.ex"))
    |> Enum.flat_map(&scan_list(&1, ~r/System\.get_env\("((?:WB|CF|FLY|NEXUS|AUTOPOET)_[A-Z_]+|PORT)"/))
    |> MapSet.new()
  end

  defp verb_doc?(body, v), do: Regex.match?(~r/(?:work |[|`] ?)#{Regex.escape(v)}\b/, body)
  defp substr_doc?(body, t), do: String.contains?(body, t)
  defp word_doc?(body, w), do: Regex.match?(~r/\b#{Regex.escape(w)}\b/, body)

  defp scan(path, rx), do: scan_list(path, rx) |> MapSet.new()

  defp scan_list(path, rx) do
    if File.exists?(path), do: Regex.scan(rx, File.read!(path)) |> Enum.map(fn [_, m] -> m end), else: []
  end

  defp skills_body(root) do
    Path.join(root, "skills") |> Path.join("**/*.work") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
  end

  defp preview(set) do
    list = Enum.sort(set)
    if length(list) > 12, do: (Enum.take(list, 12) |> Enum.join(", ")) <> " … (+#{length(list) - 12})", else: Enum.join(list, ", ")
  end
end

SkillsLint.run()
