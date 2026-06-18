defmodule Nexus.Deploy do
  @moduledoc """
  Run a nexus locally. The local target is a **krunvm** microVM on macOS (`Nexus.Deploy.Machine`),
  the mac arm of a cross-platform seam — podman/docker/WSL2 and a cloud machine slot in behind the
  same contract: **preflight → create → run → status → down**. One OCI image, run the same way
  locally or in the cloud (the canonical two-target model the runtime established).

  `local/2` boots the nexus image in a local microVM; `down/0` stops it. NOTE: this needs the nexus
  OCI image built (a `mix release` + a Dockerfile bundling wasmtime/the compilers) — the run logic
  is here and proven; the image recipe is the remaining piece.
  """
  alias Nexus.Deploy.Machine

  @doc "Boot the nexus OCI `image` in a local microVM. `{:ok, %{url, host_port, …}} | {:error, _}`."
  def local(image, opts \\ []) do
    with :ok <- Machine.preflight(),
         :ok <- Machine.ensure_apfs_volume(),
         {:ok, info} <- Machine.create(image, opts),
         {:ok, _} <- Machine.spawn_direct(Keyword.get(opts, :env, %{})) do
      {:ok, info}
    else
      {:error, reason, hint} -> {:error, {reason, hint}}
      other -> other
    end
  end

  @doc "Whether the local nexus microVM is defined/running."
  def status, do: %{target: :local, running: Machine.exists?()}

  @doc "Stop + remove the local nexus microVM."
  def down, do: Machine.down()
end
