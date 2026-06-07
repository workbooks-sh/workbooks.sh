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

  @doc "The canonical image reference (overridable via WB_IMAGE for local pins)."
  def ref(tag \\ "latest"), do: System.get_env("WB_IMAGE") || "#{@registry}/#{@name}:#{tag}"

  @doc """
  Build the runtime image for ONE platform and load it into the local docker (and,
  if `into_krunvm: true`, copy it into krunvm's buildah store so `wb deploy local`
  can run it offline). Default platform = the host arch.
  """
  def build(opts \\ []) do
    platform = Keyword.get(opts, :platform, host_platform())
    tag = ref(Keyword.get(opts, :tag, "latest"))

    with {:ok, root} <- repo_root(),
         args = ["buildx", "build", "-f", @dockerfile, "--platform", platform, "-t", tag, "--load", "."],
         {:ok, _} <- sh("docker", args, root) do
      if Keyword.get(opts, :into_krunvm, false), do: into_krunvm(tag), else: {:ok, "built #{tag} (#{platform})"}
    end
  end

  @doc """
  Build multi-arch (amd64 for cloud + arm64 for mac/krunvm) and PUSH to the
  registry — `latest` plus the current git sha. Requires a `docker login` to the
  registry (CI uses GITHUB_TOKEN; a maintainer uses a PAT).
  """
  def publish(opts \\ []) do
    platforms = Keyword.get(opts, :platforms, "linux/amd64,linux/arm64")

    with {:ok, root} <- repo_root() do
      sha = git_sha(root)
      tags = ["-t", ref("latest"), "-t", ref(sha)]
      args = ["buildx", "build", "-f", @dockerfile, "--platform", platforms] ++ tags ++ ["--push", "."]

      case sh("docker", args, root) do
        {:ok, _} -> {:ok, "published #{ref("latest")} + #{ref(sha)} (#{platforms})"}
        err -> err
      end
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

  defp sh(cmd, args, cwd) do
    {out, code} = System.cmd(cmd, args, stderr_to_stdout: true, cd: cwd)
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    ErlangError -> :error
  end
end
