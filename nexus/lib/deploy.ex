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

  # ── cloud target (the hosted control plane on Fly) ─────────────────────────────────────────────
  @control_plane_app "wb-nexus-cp"
  @control_plane_config "nexus/deploy/control-plane/fly.toml"

  @doc """
  Deploy the control-plane to Fly (image-based, no local build) — `fly deploy` against
  `nexus/deploy/control-plane/fly.toml`.

  GUARDED: refuses unless `WB_ALLOW_CP_DEPLOY=1`. The current published nexus image must already
  contain the control-plane API + auth AND be adversarially verified before you set it — deploying an
  image without `Nexus.Platform` would take the live dashboard from working to broken. The guard makes
  an accidental call a no-op, not an outage. `opts`: `:app`, `:config`, `:image`, `:remote_only`.
  """
  def cloud(opts \\ []) do
    cond do
      System.get_env("WB_ALLOW_CP_DEPLOY") not in ~w(1 true) ->
        {:error, :deploy_guarded}

      bin = System.find_executable("fly") || System.find_executable("flyctl") ->
        {out, code} = System.cmd(bin, cloud_args(opts), stderr_to_stdout: true)
        if code == 0, do: {:ok, out}, else: {:error, {:fly_deploy_failed, code, out}}

      true ->
        {:error, :flyctl_missing}
    end
  end

  @doc "The `fly deploy` argv (pure — exposed for testing the command shape without running it)."
  def cloud_args(opts \\ []) do
    app = Keyword.get(opts, :app, @control_plane_app)
    config = Keyword.get(opts, :config, @control_plane_config)
    base = ["deploy", "--config", config, "--app", app]
    base = base ++ if(img = opts[:image], do: ["--image", img], else: [])
    base ++ if(opts[:remote_only], do: ["--remote-only"], else: [])
  end
end
