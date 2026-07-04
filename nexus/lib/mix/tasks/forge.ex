defmodule Mix.Tasks.Forge do
  @shortdoc "Local micro-VM compute terminals — the agent's build failsafe (WB_FORGE=1)"
  @moduledoc """
  Drive `Nexus.Forge` — throwaway local Linux micro-VMs for builds the WASM sandbox can't host. LOCAL-ONLY
  (needs `WB_FORGE=1`; hard-false on a deployed nexus). See `nexus/docs/micro-vms.md`.

      WB_FORGE=1 mix forge run "<cmd>"           # one-shot: open a VM, run, print, close
      WB_FORGE=1 mix forge open <name>           # open a persistent terminal
      WB_FORGE=1 mix forge run <name> "<cmd>"    # run in a named terminal (open once, run many)
      WB_FORGE=1 mix forge close <name>          # tear it down
      mix forge list                             # list terminals
  """
  use Mix.Task

  @impl true
  def run(["list"]) do
    for t <- Nexus.Forge.list(), do: Mix.shell().info("  #{t.name}\t#{t.status}")
    :ok
  end

  def run(["open", name]) do
    case Nexus.Forge.open(name: name) do
      {:ok, t} -> Mix.shell().info("opened #{t.name}")
      err -> fail(err)
    end
  end

  def run(["close", name]) do
    Nexus.Forge.close(%{name: "forge-" <> name})
    Mix.shell().info("closed forge-#{name}")
  end

  # `mix forge run <name> "<cmd>"` — run in a named (persistent) terminal.
  def run(["run", name, cmd]) do
    exec(%{name: "forge-" <> name}, cmd)
  end

  # `mix forge run "<cmd>"` — one-shot: open a throwaway VM, run, close.
  def run(["run", cmd]) do
    case Nexus.Forge.open() do
      {:ok, t} ->
        try do
          exec(t, cmd)
        after
          Nexus.Forge.close(t)
        end

      err ->
        fail(err)
    end
  end

  def run(_), do: Mix.shell().info(@moduledoc)

  defp exec(terminal, cmd) do
    case Nexus.Forge.run(terminal, cmd) do
      {:ok, %{out: out, exit: code}} ->
        Mix.shell().info(out)
        if code != 0, do: exit({:shutdown, code})

      err ->
        fail(err)
    end
  end

  defp fail(err) do
    Mix.shell().error("forge: #{inspect(err)}")
    exit({:shutdown, 1})
  end
end
