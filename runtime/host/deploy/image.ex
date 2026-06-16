defmodule Workbooks.Deploy.Image do
  @moduledoc """
  The runtime IMAGE recipe — building + publishing the ONE OCI image, owned by the
  deploy-kit (not a bespoke CI pipeline). `work deploy build` makes a local
  single-arch image; `work deploy publish` pushes multi-arch to the registry. CI and
  the desktop app call these same verbs — one source of deploy truth, dogfooded.

  Shells to `docker buildx` (as the local backend shells to krunvm). The Dockerfile,
  tags, platforms, and registry live HERE so every caller agrees.
  """
  @registry "ghcr.io/workbooks-sh"
  @name "runtime"
  @dockerfile "ci/Dockerfile.runtime"
  # The in-sandbox compilers ship as a SEPARATE layer (Dockerfile.compilers) the runtime image pulls
  # via COPY --from — so CI never rebuilds the hours-long provision chain. See publish_compilers/1.
  @compilers_name "compilers"
  @compilers_dockerfile "ci/Dockerfile.compilers"
  @compilers_local "compilers:local"

  @doc "The canonical image reference (overridable via WB_IMAGE for local pins)."
  def ref(tag \\ "latest"), do: System.get_env("WB_IMAGE") || "#{@registry}/#{@name}:#{tag}"

  @doc "The compilers layer reference (overridable via WB_COMPILERS_IMAGE)."
  def compilers_ref(tag \\ "latest"), do: System.get_env("WB_COMPILERS_IMAGE") || "#{@registry}/#{@compilers_name}:#{tag}"

  @doc """
  Build the runtime image for ONE platform and load it into the local docker (and,
  if `into_krunvm: true`, copy it into krunvm's buildah store so `work deploy local`
  can run it offline). Default platform = the host arch.
  """
  def build(opts \\ []) do
    platform = Keyword.get(opts, :platform, host_platform())
    tag = ref(Keyword.get(opts, :tag, "latest"))

    # Plain `docker build` (not buildx) for the LOCAL single-arch image — it loads
    # into the docker daemon by default and needs no buildx plugin (colima ships
    # without it). buildx stays for multi-arch publish/0. BuildKit (default engine)
    # is required for the ARG-driven `COPY --from=${TOOLS_REF}`.
    with {:ok, root} <- repo_root(),
         {:ok, compilers} <- ensure_compilers_local(root, opts),
         args = ["build", "-f", @dockerfile, "--platform", platform,
                 "--build-arg", "COMPILERS_REF=#{compilers}", "-t", tag, "."],
         {:ok, _} <- sh("docker", args, root, [{"DOCKER_BUILDKIT", "1"}]) do
      if Keyword.get(opts, :into_krunvm, false), do: into_krunvm(tag), else: {:ok, "built #{tag} (#{platform}, compilers #{compilers})"}
    end
  end

  @doc """
  Build multi-arch (amd64 for cloud + arm64 for mac/krunvm) and PUSH to the
  registry — `latest` plus the current git sha. Requires a `docker login` to the
  registry (CI uses GITHUB_TOKEN; a maintainer uses a PAT).
  """
  def publish(opts \\ []) do
    # WB_PLATFORMS lets CI build a single arch NATIVELY (no QEMU) — e.g. arm64 on
    # an arm runner — which is ~10× faster than emulated multi-arch.
    platforms = Keyword.get(opts, :platforms, System.get_env("WB_PLATFORMS", "linux/amd64,linux/arm64"))

    compilers = Keyword.get(opts, :compilers_ref, compilers_ref("latest"))

    with {:ok, root} <- repo_root() do
      sha = git_sha(root)
      tags = ["-t", ref("latest"), "-t", ref(sha)]
      args =
        ["buildx", "build", "-f", @dockerfile, "--platform", platforms, "--build-arg", "COMPILERS_REF=#{compilers}"] ++
          tags ++ ["--push", "."]

      case sh("docker", args, root) do
        {:ok, _} -> {:ok, "published #{ref("latest")} + #{ref(sha)} (#{platforms}, compilers #{compilers})"}
        err -> err
      end
    end
  end

  @doc """
  Build the compilers LAYER locally (the lean in-sandbox compilers, from compilers-dist/) and load
  it into docker as `compilers:local`. Stages the bundle first via scripts/stage-tools.sh, so it
  needs the provisioned compilers/ tree present. `build/1` calls this automatically; run it directly
  to refresh the local compilers layer. Returns {:ok, tag}.
  """
  def build_compilers(opts \\ []) do
    tag = Keyword.get(opts, :tag, @compilers_local)

    with {:ok, root} <- repo_root(),
         :ok <- stage_compilers(root),
         args = ["build", "-f", @compilers_dockerfile, "-t", tag, "."],
         {:ok, _} <- sh("docker", args, root) do
      {:ok, tag}
    end
  end

  @doc """
  Build the compilers layer MULTI-ARCH and PUSH to ghcr — run from a PROVISIONED machine (it stages
  from the local compilers tree). The compilers rarely change, so this is occasional; the cloud
  `publish/1` then references the pushed `compilers:latest`. Tagged `latest` + the git sha.
  Requires a `docker login` to the registry.
  """
  def publish_compilers(opts \\ []) do
    platforms = Keyword.get(opts, :platforms, System.get_env("WB_PLATFORMS", "linux/amd64,linux/arm64"))

    with {:ok, root} <- repo_root(),
         :ok <- stage_compilers(root) do
      sha = git_sha(root)
      tags = ["-t", compilers_ref("latest"), "-t", compilers_ref(sha)]
      args = ["buildx", "build", "-f", @compilers_dockerfile, "--platform", platforms] ++ tags ++ ["--push", "."]

      case sh("docker", args, root) do
        {:ok, _} -> {:ok, "published #{compilers_ref("latest")} + #{compilers_ref(sha)} (#{platforms})"}
        err -> err
      end
    end
  end

  # Resolve the compilers layer for a LOCAL runtime build: an explicit :compilers_ref wins; else
  # reuse an already-built compilers:local (unless :rebuild_compilers); else build it now.
  defp ensure_compilers_local(_root, opts) do
    cond do
      Keyword.get(opts, :compilers_ref) -> {:ok, Keyword.get(opts, :compilers_ref)}
      not Keyword.get(opts, :rebuild_compilers, false) and image_present?(@compilers_local) -> {:ok, @compilers_local}
      true -> build_compilers(Keyword.put(opts, :tag, @compilers_local))
    end
  end

  defp image_present?(tag), do: match?({:ok, _}, sh("docker", ["image", "inspect", tag], "."))

  # Stage the lean in-sandbox compilers (~600M) into runtime/compilers-dist via scripts/stage-tools.sh.
  defp stage_compilers(root) do
    script = Path.join(root, "runtime/scripts/stage-tools.sh")

    if File.regular?(script) do
      case sh("bash", [script], Path.join(root, "runtime")) do
        {:ok, _} -> :ok
        {:error, out} -> {:error, "stage-tools failed: #{String.slice(out, max(0, String.length(out) - 400), 400)}"}
        :error -> {:error, "bash not found for stage-tools"}
      end
    else
      {:error, "missing #{script} — provision the compile tools first"}
    end
  end

  # Copy a docker-built image into krunvm's buildah/containers store so the local
  # microVM can boot it without a registry round-trip.
  defp into_krunvm(tag) do
    case sh("skopeo", ["copy", "docker-daemon:#{tag}", "containers-storage:#{tag}"], ".") do
      {:ok, _} -> {:ok, "built + staged into krunvm store: #{tag}"}
      :error -> {:error, "skopeo not found — `brew install skopeo` (needed to stage a local image into krunvm)"}
      {:error, out} -> {:error, "skopeo copy failed: #{out}"}
    end
  end

  defp host_platform do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "aarch64" <> _ -> "linux/arm64"
      _ -> "linux/amd64"
    end
  end

  defp git_sha(root) do
    case sh("git", ["rev-parse", "--short", "HEAD"], root) do
      {:ok, out} -> String.trim(out)
      _ -> "dev"
    end
  end

  # Walk up from CWD for the repo root holding the Dockerfile.
  defp repo_root do
    start = File.cwd!()

    Enum.reduce_while(0..8, start, fn _, dir ->
      if File.exists?(Path.join(dir, @dockerfile)), do: {:halt, {:ok, dir}}, else: {:cont, Path.dirname(dir)}
    end)
    |> case do
      {:ok, _} = ok -> ok
      _ -> {:error, "could not find #{@dockerfile} from #{start}"}
    end
  end

  defp sh(cmd, args, cwd, env \\ []) do
    {out, code} = System.cmd(cmd, args, stderr_to_stdout: true, cd: cwd, env: env)
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    ErlangError -> :error
  end
end
