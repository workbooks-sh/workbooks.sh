defmodule Mix.Tasks.Nexus.Check do
  @moduledoc """
  Run a workbook's self-validation checks — author agents + `check` directives in a `.work` file,
  then `mix nexus.check <dir>` runs each check's agent and reports pass/fail. Exits non-zero if any
  check fails (CI-friendly).

      mix nexus.check examples/agent-demo
  """
  @shortdoc "Run a workbook's self-validating checks"
  use Mix.Task

  @impl true
  def run(args) do
    root = List.first(args) || "."
    Mix.Task.run("app.start")

    report = Nexus.Checks.run(root)

    for r <- report.results do
      mark = if r.passed, do: "PASS", else: "FAIL"
      detail = r.error || r.got || ""
      Mix.shell().info("[#{mark}] #{r.name} — expect #{r.expect}#{if detail != "", do: " — got: #{String.slice(detail, 0, 80)}", else: ""}")
    end

    Mix.shell().info("\n#{report.passed} passed, #{report.failed} failed")
    if report.failed > 0, do: exit({:shutdown, 1})
  end
end
