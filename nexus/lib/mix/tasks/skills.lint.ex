defmodule Mix.Tasks.Skills.Lint do
  @shortdoc "Skills anti-drift gate + coverage dashboard"
  @moduledoc """
  Local convenience over the canonical `ci/skills-lint.exs` — the same gate CI runs. Verifies `skills/`
  stays accurate against the ACTUAL code (the `work` verbs are a hard gate; API routes / `.work` blocks /
  env knobs are a coverage dashboard). Exits non-zero on drift.

      mix skills.lint      # == elixir ci/skills-lint.exs

  The logic lives in `ci/skills-lint.exs` (self-contained, no nexus compile) so it's the single source of
  truth for both CI and here — no second copy to drift.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    root =
      Enum.find([File.cwd!(), Path.expand(".."), Path.expand("../..")], fn d ->
        File.exists?(Path.join([d, "ci", "skills-lint.exs"]))
      end) || Path.expand("..")

    {out, code} = System.cmd("elixir", [Path.join([root, "ci", "skills-lint.exs"])], stderr_to_stdout: true)
    IO.write(out)
    if code != 0, do: exit({:shutdown, code})
  end
end
