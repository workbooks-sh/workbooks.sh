defmodule Mix.Tasks.Nexus.Deploy.Local do
  @moduledoc """
  Boot the nexus OCI runtime image in a local vfkit microVM (real virtio-net NIC) — the deploy bridge the `work` CLI
  (`work deploy apply`, local target) invokes. ONE source of truth for the boot contract:
  `Nexus.Deploy.local/2` → `Nexus.Deploy.Machine` (vfkit boot of the engine-disk).

      mix nexus.deploy.local                 # image from Nexus.Config / WB_IMAGE
      mix nexus.deploy.local ghcr.io/…/runtime:latest

  Prints the booted nexus URL on success; surfaces Machine's real error otherwise (e.g. no image
  built/pulled yet — see Nexus.Deploy.Machine).
  """
  @shortdoc "Boot the nexus runtime image locally (vfkit) — `work deploy apply` bridge"
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    # `--update` force-repulls the engine-disk (otherwise it auto-refreshes only when the published
    # disk's digest has drifted past the cached golden). The first positional arg is the (informational) image.
    {update?, rest} = {Enum.member?(args, "--update"), Enum.reject(args, &(&1 == "--update"))}
    image = List.first(rest) || default_image()

    case Nexus.Deploy.local(image, update: update?) do
      {:ok, info} ->
        Mix.shell().info("nexus booted · #{Map.get(info, :url, "http://127.0.0.1:4000")}")

      {:error, reason} ->
        Mix.shell().error("local boot failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp default_image do
    System.get_env("WB_IMAGE") ||
      (function_exported?(Nexus.Config, :runtime_image, 0) && Nexus.Config.runtime_image()) ||
      "ghcr.io/workbooks-sh/runtime:latest"
  end
end
