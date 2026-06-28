defmodule Mix.Tasks.Test262.Fetch do
  use Mix.Task

  @shortdoc "Clone/update the FULL tc39/test262 suite into the gitignored .test262/"

  @moduledoc """
  Bootstraps the **entire** ECMAScript spec suite locally so any region is one command away — the committed
  slice is just the cheap CI gate, NOT the limit of what you can run. The full ~50k-case clone lives in the
  gitignored `.test262/`; this fetches or fast-forwards it.

      mix test262.fetch          # clone (shallow) or `git pull` an existing clone

  Then run any part on the ASM lane on demand:

      mix test262 built-ins/Array          # any subdir of the full suite
      mix test262 language/expressions     # a whole region
      mix test262 --slice                  # the committed curated slice (== the gate)
  """
  def run(_argv) do
    root = Nexus.Test262.clone_root()

    if File.dir?(Path.join(root, ".git")) do
      Mix.shell().info("updating #{root} …")
      {out, _} = System.cmd("git", ["-C", root, "pull", "--ff-only"], stderr_to_stdout: true)
      Mix.shell().info(out)
    else
      Mix.shell().info("cloning tc39/test262 → #{root} (shallow) …")
      {out, code} =
        System.cmd("git", ["clone", "--depth", "1", "https://github.com/tc39/test262.git", root],
          stderr_to_stdout: true
        )

      Mix.shell().info(out)
      if code != 0, do: Mix.raise("clone failed (#{code})")
    end

    n = Path.wildcard(Path.join([root, "test", "**", "*.js"])) |> length()
    Mix.shell().info("full suite ready: #{n} test files under #{Path.relative_to_cwd(root)}/test/")
  end
end
