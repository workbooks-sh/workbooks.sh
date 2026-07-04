defmodule Mix.Tasks.Skills.Lint do
  @shortdoc "Skills coverage dashboard + anti-drift gate against the source of truth"
  @moduledoc """
  Keeps `skills/` honest against the ACTUAL code so skills can never silently rot. For each **surface** an
  agent can touch, it extracts the ground truth straight from source and measures how much the skills cover:

    * **`work` CLI verbs** (`cli/src/main.zig`) — a **hard GATE**: an uncovered verb fails CI.
    * **API routes** (`platform.ex` / `cloud/api.ex`), **`.work` block kinds** (the real corpus), and
      **config/env knobs** (`System.get_env`) — a **coverage DASHBOARD**: reported, not gated (many are
      internal), so you can *see* how much of the agent-facing surface is documented and where the gaps are.

  Drift on a gated surface exits non-zero — wire it into CI next to `mix compile` and drift can't merge.

      mix skills.lint            # dashboard + gate
  """
  use Mix.Task

  @impl true
  def run(_args) do
    root = repo_root()
    body = skills_body(root)

    surfaces = [
      %{kind: :gate, name: "work CLI verbs", truth: cli_verbs(root), doc: &verb_doc?/2, exempt: ~w(help version)},
      %{kind: :dash, name: "API routes", truth: api_routes(root), doc: &substr_doc?/2, exempt: []},
      %{kind: :dash, name: ".work block kinds", truth: work_blocks(root), doc: &word_doc?/2, exempt: []},
      %{kind: :dash, name: "config/env knobs", truth: env_knobs(root), doc: &substr_doc?/2, exempt: []}
    ]

    Mix.shell().info("skills.lint · agent-facing surface coverage (source of truth → skills/)")

    drift? =
      Enum.reduce(surfaces, false, fn s, acc ->
        truth = MapSet.difference(s.truth, MapSet.new(s.exempt))
        uncovered = truth |> Enum.reject(&s.doc.(body, &1)) |> MapSet.new()
        total = MapSet.size(truth)
        cov = total - MapSet.size(uncovered)
        gate = if s.kind == :gate, do: " [GATE]", else: ""
        Mix.shell().info("  #{String.pad_trailing(s.name, 18)} #{cov}/#{total}#{gate}")

        if MapSet.size(uncovered) > 0 do
          tag = if s.kind == :gate, do: "DRIFT", else: "gap"
          Mix.shell().info("      #{tag}: #{preview(uncovered)}")
        end

        acc or (s.kind == :gate and MapSet.size(uncovered) > 0)
      end)

    if drift? do
      Mix.shell().error("✗ drift on a GATED surface — update skills/ (or the code) before merge")
      exit({:shutdown, 1})
    else
      Mix.shell().info("✓ no drift on gated surfaces")
    end
  end

  # ── extractors: ground truth from source ──────────────────────────────────────────────────────
  defp cli_verbs(root),
    do: scan(Path.join([root, "cli", "src", "main.zig"]), ~r/eql\(verb, "([a-z]+)"\)/)

  defp api_routes(root) do
    ~w(nexus/lib/platform.ex nexus/lib/cloud/api.ex)
    |> Enum.flat_map(&scan_list(Path.join(root, &1), ~r/\b(?:get|post|put|delete)\s+"(\/[^"]*)"/))
    |> Enum.map(&Regex.replace(~r/\/:[a-z_]+/, &1, ""))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  # Block kinds actually used across the real .work corpus (a bare `<kind> [lang] :name … do` header).
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

  # ── doc-checks: is this surface item mentioned in the skills? ──────────────────────────────────
  defp verb_doc?(body, v), do: Regex.match?(~r/(?:work |[|`] ?)#{Regex.escape(v)}\b/, body)
  defp substr_doc?(body, t), do: String.contains?(body, t)
  defp word_doc?(body, w), do: Regex.match?(~r/\b#{Regex.escape(w)}\b/, body)

  # ── helpers ───────────────────────────────────────────────────────────────────────────────────
  defp scan(path, rx), do: scan_list(path, rx) |> MapSet.new()

  defp scan_list(path, rx) do
    if File.exists?(path),
      do: Regex.scan(rx, File.read!(path)) |> Enum.map(fn [_, m] -> m end),
      else: []
  end

  defp skills_body(root) do
    Path.join(root, "skills") |> Path.join("**/*.work") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
  end

  defp preview(set) do
    list = Enum.sort(set)
    shown = Enum.take(list, 12) |> Enum.join(", ")
    if length(list) > 12, do: shown <> " … (+#{length(list) - 12})", else: shown
  end

  defp repo_root do
    Enum.find([File.cwd!(), Path.expand(".."), Path.expand("../..")], fn d ->
      File.exists?(Path.join([d, "cli", "src", "main.zig"]))
    end) || Path.expand("..")
  end
end
