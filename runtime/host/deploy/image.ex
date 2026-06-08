defmodule Workbooks.Deploy.Image do
  @moduledoc """
  The runtime IMAGE recipe — building + publishing the ONE OCI image, owned by the
  deploy-kit (not a bespoke CI pipeline). `wb deploy build` makes a local
  single-arch image; `wb deploy publish` pushes multi-arch to the registry. CI and
  the desktop app call these same verbs — one source of deploy truth, dogfooded.

  Shells to `docker buildx` (as the local backend shells to krunvm). The Dockerfile,
  tags, platforms, and registry live HERE so every caller agrees.
  """
  @registry "ghcr.io/workbooks-sh"
  @name "runtime"
  @dockerfile "deploy/Dockerfile.runtime"
  # The in-sandbox compile toolchain ships as a SEPARATE layer (Dockerfile.tools) the runtime image
  # pulls via COPY --from — so CI never rebuilds the hours-long provision chain. See publish_tools/1.
  @tools_name "runtime-tools"
  @tools_dockerfile "deploy/Dockerfile.tools"
  @tools_local "runtime-tools:local"

  @doc "The canonical image reference (overridable via WB_IMAGE for local pins)."
  def ref(tag \\ "latest"), do: System.get_env("WB_IMAGE") || "#{@registry}/#{@name}:#{tag}"

  @doc "The runtime-tools layer reference (overridable via WB_TOOLS_IMAGE)."
  def tools_ref(tag \\ "latest"), do: System.get_env("WB_TOOLS_IMAGE") || "#{@registry}/#{@tools_name}:#{tag}"

  @doc """
  Build the runtime image for ONE platform and load it into the local docker (and,
  if `into_krunvm: true`, copy it into krunvm's buildah store so `wb deploy local`
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
         {:ok, tools} <- ensure_tools_local(root, opts),
         args = ["build", "-f", @dockerfile, "--platform", platform,
                 "--build-arg", "TOOLS_REF=#{tools}", "-t", tag, "."],
         {:ok, _} <- sh("docker", args, root, [{"DOCKER_BUILDKIT", "1"}]) do
      if Keyword.get(opts, :into_krunvm, false), do: into_krunvm(tag), else: {:ok, "built #{tag} (#{platform}, tools #{tools})"}
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

    tools = Keyword.get(opts, :tools_ref, tools_ref("latest"))

    with {:ok, root} <- repo_root() do
      sha = git_sha(root)
      tags = ["-t", ref("latest"), "-t", ref(sha)]
      args =
        ["buildx", "build", "-f", @dockerfile, "--platform", platforms, "--build-arg", "TOOLS_REF=#{tools}"] ++
          tags ++ ["--push", "."]

      case sh("docker", args, root) do
        {:ok, _} -> {:ok, "published #{ref("latest")} + #{ref(sha)} (#{platforms}, tools #{tools})"}
        err -> err
      end
    end
  end

  @doc """
  Build the runtime-tools LAYER locally (the lean compile toolchain, from compilers-dist/) and load
  it into docker as `runtime-tools:local`. Stages the bundle first via scripts/stage-tools.sh, so it
  needs the provisioned compilers/ tree present. `build/1` calls this automatically; run it directly
  to refresh the local tools layer. Returns {:ok, tag}.
  """
  def build_tools(opts \\ []) do
    tag = Keyword.get(opts, :tag, @tools_local)

    with {:ok, root} <- repo_root(),
         :ok <- stage_tools(root),
         args = ["build", "-f", @tools_dockerfile, "-t", tag, "."],
         {:ok, _} <- sh("docker", args, root) do
      {:ok, tag}
    end
  end

  @doc """
  Build the runtime-tools layer MULTI-ARCH and PUSH to ghcr — run from a PROVISIONED machine (it
  stages from the local compilers tree). The toolchain rarely changes, so this is occasional; the
  cloud `publish/1` then references the pushed `runtime-tools:latest`. Tagged `latest` + the git sha.
  Requires a `docker login` to the registry.
  """
  def publish_tools(opts \\ []) do
    platforms = Keyword.get(opts, :platforms, System.get_env("WB_PLATFORMS", "linux/amd64,linux/arm64"))

    with {:ok, root} <- repo_root(),
         :ok <- stage_tools(root) do
      sha = git_sha(root)
      tags = ["-t", tools_ref("latest"), "-t", tools_ref(sha)]
      args = ["buildx", "build", "-f", @tools_dockerfile, "--platform", platforms] ++ tags ++ ["--push", "."]

      case sh("docker", args, root) do
        {:ok, _} -> {:ok, "published #{tools_ref("latest")} + #{tools_ref(sha)} (#{platforms})"}
        err -> err
      end
    end
  end

  # Resolve the tools layer for a LOCAL runtime build: an explicit :tools_ref wins; else reuse an
  # already-built runtime-tools:local (unless :rebuild_tools); else build it now from compilers-dist.
  defp ensure_tools_local(_root, opts) do
    cond do
      Keyword.get(opts, :tools_ref) -> {:ok, Keyword.get(opts, :tools_ref)}
      not Keyword.get(opts, :rebuild_tools, false) and image_present?(@tools_local) -> {:ok, @tools_local}
      true -> build_tools(Keyword.put(opts, :tag, @tools_local))
    end
  end

  defp image_present?(tag), do: match?({:ok, _}, sh("docker", ["image", "inspect", tag], "."))

  # Stage the lean compile toolchain (~600M) into runtime/compilers-dist via scripts/stage-tools.sh.
  defp stage_tools(root) do
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
