defmodule Mix.Tasks.Nexus.Reactor do
  @shortdoc "Build the Zig toolchain reactor + stage it into nexus/priv (work-toolchain.wasm)"
  @moduledoc @shortdoc
  use Mix.Task

  @impl true
  def run(_args) do
    script = Path.expand("../../../scripts/stage-reactor.sh", __DIR__)
    {out, code} = System.cmd("sh", [script], stderr_to_stdout: true)
    IO.puts(out)
    if code != 0, do: Mix.raise("stage-reactor failed (#{code})")
  end
end
