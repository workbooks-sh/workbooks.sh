defmodule Mix.Tasks.Test262 do
  use Mix.Task

  @shortdoc "Run a test262 subdir on the Porffor→Washy ASM lane; print pass% + grouped failures"

  @moduledoc """
  Cheap, on-demand language-gap probing against the official ECMAScript spec suite, on the **ASM lane**.

      mix test262 built-ins/RegExp/prototype/exec        # a subdir of the gitignored full clone (.test262/)
      mix test262 language/statements/for-of --limit 50  # cap the run
      mix test262 --slice                                 # run the committed curated slice

  Path is relative to `.test262/test/` (the full clone) unless `--slice` is given, in which case it runs the
  committed `test/conformance/test262/cases/`. node is an ORACLE only (via the vendored assert.js/sta.js);
  the lane is the thing under test. Use this to probe a language area before a future rung (Svelte/Vite/React)
  without paying the 5-minute bundle cost.
  """

  @switches [limit: :integer, slice: :boolean, fuel: :integer]

  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.start")

    {dir, label, hopts} =
      if opts[:slice] do
        base = Path.join([File.cwd!(), "test", "conformance", "test262"])
        {Path.join(base, "cases"), "committed slice", [harness_dir: Path.join(base, "harness")]}
      else
        sub = List.first(args) || Mix.raise("usage: mix test262 <subdir>  (or --slice)")
        {Path.join([Nexus.Test262.clone_root(), "test", sub]), sub, []}
      end

    unless File.dir?(dir), do: Mix.raise("not a dir: #{dir}")

    ropts =
      hopts
      |> then(&if(opts[:limit], do: [{:limit, opts[:limit]} | &1], else: &1))
      |> then(&if(opts[:fuel], do: [{:fuel, opts[:fuel]} | &1], else: &1))

    {_results, summary} = Nexus.Test262.run_dir(dir, ropts)
    IO.puts(Nexus.Test262.format_report(summary, label))
  end
end
