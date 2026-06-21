defmodule Mix.Tasks.Nexus.Deploy.Down do
  @moduledoc """
  Stop + remove the local nexus microVM — the teardown bridge `work deploy down` (local target)
  invokes. Delegates to `Nexus.Deploy.down/0` → `Nexus.Deploy.Machine.down/0` (kill + krunvm delete);
  the APFS volume + image store are left intact so it can be re-applied.

      mix nexus.deploy.down
  """
  @shortdoc "Stop + remove the local nexus microVM — `work deploy down` bridge"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    _ = Nexus.Deploy.down()
    Mix.shell().info("local nexus stopped + removed")
  end
end
