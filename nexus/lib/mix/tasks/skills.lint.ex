defmodule Mix.Tasks.Skills.Lint do
  @shortdoc "Lint skills against the source of truth — fail on drift (the CI anti-drift gate)"
  @moduledoc """
  Keeps `skills/` accurate against the ACTUAL code so skills can never silently rot. It extracts the real
  **surfaces** an agent can touch straight from source, then checks the skills cover them:

    * **uncovered** — a real surface no skill mentions (e.g. a new `work` verb) → the skill is stale.
    * **phantom**   — a skill names a surface that no longer exists → the skill lies.

  Both are CI failures (non-zero exit). Today it gates the highest-churn surface, the `work` CLI verbs
  (source of truth: `cli/src/main.zig`). It is built to grow — add extractors to `surfaces/1` for API
  routes (`platform.ex`/`cloud/api.ex`), `.work` block kinds (`literate.ex`), and config/secret keys.

      mix skills.lint            # report coverage + drift, exit non-zero on drift
      mix skills.lint --strict   # also fail on phantom mentions
  """
  use Mix.Task

  @impl true
  def run(args) do
    strict? = "--strict" in args
    root = repo_root()

    {code, doc, phantom} = surface("work CLI verbs", cli_verbs(root), skills_body(root), &documented?/2)

    total = MapSet.size(code)
    uncovered = MapSet.difference(code, doc)
    Mix.shell().info("skills.lint · work CLI verbs: #{total - MapSet.size(uncovered)}/#{total} covered")

    drift? = MapSet.size(uncovered) > 0 or (strict? and MapSet.size(phantom) > 0)

    if MapSet.size(uncovered) > 0,
      do: Mix.shell().error("  UNCOVERED (real verb, no skill): #{join(uncovered)}")

    if MapSet.size(phantom) > 0,
      do: Mix.shell().info("  phantom? (named in a skill, not a verb — may be prose): #{join(phantom)}")

    if drift? do
      Mix.shell().error("  ✗ drift — update skills/ (or the code) before merge")
      exit({:shutdown, 1})
    else
      Mix.shell().info("  ✓ no drift")
    end
  end

  # (ground-truth set, documented set, phantom set) for one surface.
  defp surface(_name, code, body, doc_fun) do
    documented = code |> Enum.filter(&doc_fun.(body, &1)) |> MapSet.new()
    # phantom = tokens the skills present as verbs (`work <x>`) that aren't real verbs.
    mentioned = Regex.scan(~r/work ([a-z]+)\b/, body) |> Enum.map(fn [_, v] -> v end) |> MapSet.new()
    {code, documented, MapSet.difference(mentioned, code)}
  end

  # Ground truth: the verb dispatch in the work CLI (`eql(verb, "<x>")`).
  defp cli_verbs(root) do
    File.read!(Path.join([root, "cli", "src", "main.zig"]))
    |> (&Regex.scan(~r/eql\(verb, "([a-z]+)"\)/, &1)).()
    |> Enum.map(fn [_, v] -> v end)
    |> MapSet.new()
  end

  # A verb is "documented" if it appears as `work <v>` or in a piped/backticked list (`why | near | wit`).
  defp documented?(body, v) do
    Regex.match?(~r/(?:work |[|`] ?)#{Regex.escape(v)}\b/, body)
  end

  defp skills_body(root) do
    Path.join(root, "skills")
    |> Path.join("**/*.work")
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp join(set), do: set |> Enum.sort() |> Enum.join(", ")

  defp repo_root do
    Enum.find([File.cwd!(), Path.expand(".."), Path.expand("../..")], fn d ->
      File.exists?(Path.join([d, "cli", "src", "main.zig"]))
    end) || Path.expand("..")
  end
end
