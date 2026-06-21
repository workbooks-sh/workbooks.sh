defmodule Nexus.Deploy do
  @moduledoc """
  Run a nexus locally. The local target is a **vfkit** microVM on macOS (`Nexus.Deploy.Machine`) —
  Apple Virtualization.framework with a real `virtio-net` NIC (the krunvm/libkrun-TSI path deadlocked
  the in-guest HTTP server — bd wb-pqf4). One runtime image, the same two-target model: local
  (vfkit) or cloud (Fly). Contract: **preflight → ensure-disk → create → run → status → down**.

  `local/2` boots the engine-disk under vfkit and returns its reachable URL; `down/0` stops it. The
  cloud target is Fly (`cloud/1`) — no microVM, no libkrun, unaffected by the local networking.
  """
  alias Nexus.Deploy.Machine

  @doc """
  Boot the nexus locally under vfkit and wait until it serves. `image` is informational (the local
  boot uses the published engine-disk artifact, the runtime image as a bootable disk). Returns
  `{:ok, %{url, ip, data_dir}}` with `url = http://<guestIP>:4000`, or `{:error, _}`.
  """
  def local(_image \\ nil, opts \\ []) do
    with :ok <- Machine.preflight(),
         {:ok, _golden} <- Machine.ensure_engine_disk(),
         {:ok, vm} <- Machine.create(opts),
         {:ok, _} <- Machine.spawn_direct(vm),
         {:ok, ip} <- Machine.await_ip(vm),
         :ok <- Machine.await_health(ip) do
      {:ok, %{url: "http://#{ip}:4000", ip: ip, data_dir: vm.data_dir}}
    else
      {:error, reason, hint} -> {:error, {reason, hint}}
      :error -> {:error, :boot_timeout}
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

  # ── deploy-as-index-tree validation (docs/deploy-as-index-tree.md) ─────────────────────────────
  # A `deploy` block is only meaningful in an `index.work`, ONE per index. The index that holds it is
  # a deployable unit; nested indexes with deploy blocks are sub-deployments (a pipeline). Used by
  # `work check` and the weave gate so a stray/duplicate deploy block fails the build, not the runtime.

  @doc """
  Validate the deploy-as-index-tree rules for the workbook tree at `root`. `:ok` or
  `{:error, problems}` where problems is a list of human-readable strings:
    * a `deploy` block in a NON-index file — drift; only `index.work` counts.
    * MORE THAN ONE `deploy` block in a single index — ambiguous; exactly one per index.
  """
  def validate(root) do
    {indexes, others} =
      (Path.wildcard(Path.join(root, "**/*.work")) ++ Path.wildcard(Path.join(root, "*.work")))
      |> Enum.uniq()
      |> Enum.split_with(&(Path.basename(&1) == "index.work"))

    stray =
      for f <- others, deploy_count(f) > 0,
        do: "deploy block in #{Path.relative_to(f, root)} — a deploy block only takes effect in index.work"

    multi =
      for f <- indexes, deploy_count(f) > 1,
        do: "#{deploy_count(f)} deploy blocks in #{Path.relative_to(f, root)} — exactly one deploy block per index"

    case stray ++ multi do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  @doc """
  The deploy nodes under `root`: every `index.work` carrying a `deploy` block, shallowest first (the
  root manifest, then sub-deployments). Single-nexus is the one-element degenerate case.
  """
  def nodes(root) do
    (Path.wildcard(Path.join(root, "**/index.work")) ++ Path.wildcard(Path.join(root, "index.work")))
    |> Enum.uniq()
    |> Enum.filter(&(deploy_count(&1) > 0))
    |> Enum.sort_by(&{length(Path.split(&1)), &1})
  end

  # Count REAL `deploy` blocks via the AST-first parser (Nexus.Literate) — never a regex, so a doc that
  # merely mentions `deploy` syntax in prose is not mistaken for a deploy block.
  defp deploy_count(path) do
    case File.read(path) do
      {:ok, src} -> src |> Nexus.Literate.parse() |> Enum.count(&(Map.get(&1, :kind) == "deploy"))
      _ -> 0
    end
  end
end
