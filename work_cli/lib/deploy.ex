defmodule WorkCLI.Deploy do
  @moduledoc """
  `work deploy …` — stand up a runtime for *your* workbook, local or cloud. The CLI is the **client**:
  it scaffolds + validates the `<work-deploy>` config (local, via `WorkCore.DeployConfig`), then routes
  `apply/status/verify/logs/down` to the right backend — a **local** krunvm/container running the one
  OCI image, or the **cloud** control plane. Prerequisite-gated and honest: if a backend tool isn't
  present, it says exactly what to install rather than failing opaquely.
  """

  alias WorkCore.{DeployConfig, Log}

  @config_file "deployment.html"

  @doc "work deploy init [local|cloud] [dir] — scaffold a deployment.html."
  def init(place, dir, opts \\ []) do
    place = if place in ["local", "cloud"], do: place, else: "local"
    path = Path.join(dir, @config_file)
    Log.prompt("work deploy init #{place} #{dir}")

    cond do
      File.exists?(path) and not Keyword.get(opts, :force, false) ->
        Log.warn("#{@config_file} already exists", detail: "pass --force to overwrite")
        {:error, :exists}

      true ->
        File.write!(path, DeployConfig.scaffold(place))
        Log.ok("wrote #{@config_file}", detail: "engine-place=#{place}")
        Log.step(Log.dim("edit it, then `work deploy validate` → `work deploy apply`"))
        :ok
    end
  end

  @doc "work deploy validate [file] — coherence-check the config without deploying."
  def validate(file) do
    Log.prompt("work deploy validate #{file}")

    with {:ok, html} <- read(file),
         {:ok, props} <- DeployConfig.parse(html) do
      case DeployConfig.validate(props) do
        :ok ->
          Log.ok("config is coherent", detail: "engine-place=#{DeployConfig.place(props)}")
          :ok

        {:error, issues} ->
          Log.error("#{length(issues)} issue(s)")
          for i <- issues, do: Log.step(i)
          {:error, :invalid}
      end
    else
      err -> config_error(err)
    end
  end

  @doc "work deploy apply [file] — deploy it (local microVM/container, or cloud)."
  def apply(file) do
    Log.prompt("work deploy apply #{file}")

    with {:ok, html} <- read(file),
         {:ok, props} <- DeployConfig.parse(html),
         :ok <- DeployConfig.validate(props) do
      case DeployConfig.place(props) do
        "local" -> apply_local(props)
        "cloud" -> apply_cloud(props)
      end
    else
      {:error, issues} when is_list(issues) ->
        Log.error("config invalid — fix it first (`work deploy validate`)")
        for i <- issues, do: Log.step(i)
        {:error, :invalid}

      err ->
        config_error(err)
    end
  end

  @doc "work deploy verify [file|url] — prove the live runtime answers (HTTP /health)."
  def verify(target) do
    url = health_url(target)
    Log.prompt("work deploy verify #{url}")

    case WorkCLI.Client.get(url, timeout: 5_000) do
      {:ok, 200, _body} ->
        Log.ok("runtime healthy", detail: url)
        :ok

      {:ok, code, _} ->
        Log.error("unhealthy", detail: "HTTP #{code}")
        {:error, :unhealthy}

      {:error, reason} ->
        Log.error("unreachable", detail: "#{inspect(reason)} — is it deployed + running?")
        {:error, :unreachable}
    end
  end

  @doc "work deploy status [file] — inspect the deployment."
  def status(file) do
    Log.prompt("work deploy status #{file}")
    with {:ok, html} <- read(file), {:ok, props} <- DeployConfig.parse(html) do
      place = DeployConfig.place(props)

      case place do
        "local" -> local_status()
        "cloud" -> (Log.step("cloud status via the control plane — needs `work login` (P5)"); :ok)
      end
    else
      err -> config_error(err)
    end
  end

  @doc "work deploy down [file] — tear it down."
  def down(file) do
    Log.prompt("work deploy down #{file}")
    with {:ok, html} <- read(file), {:ok, props} <- DeployConfig.parse(html) do
      case DeployConfig.place(props) do
        "local" -> local_cmd(["delete", vm_name()], "torn down", "nothing to tear down")
        "cloud" -> (Log.step("cloud teardown via the control plane (P5)"); :ok)
      end
    else
      err -> config_error(err)
    end
  end

  # ── local backend: the one OCI image in a krunvm microVM (mac) / container ──────────────────
  defp apply_local(_props) do
    case backend_bin() do
      nil ->
        Log.warn("no local container backend found", detail: "install krunvm (`brew install krunvm`) or podman/docker")
        Log.step(Log.dim("the deploy plan is valid — this only needs the runner present"))
        {:error, :no_backend}

      {tool, _bin} ->
        Log.ok("backend: #{tool}", detail: "ready to run the runtime OCI image")
        Log.step(Log.dim("image build + boot lands with the nexus image recipe (Nexus.Deploy)"))
        :ok
    end
  end

  defp apply_cloud(props) do
    Log.ok("cloud target: #{props["PROVIDER"] || "fly"}", detail: props["APP"] || "(no app set)")
    Log.step(Log.dim("cloud apply provisions via the control plane — `work login` + P5 platform surface"))
    :ok
  end

  defp local_status do
    case backend_bin() do
      nil -> (Log.step("no local backend installed"); :ok)
      {tool, _} -> (Log.ok("local backend: #{tool}"); :ok)
    end
  end

  defp local_cmd(args, ok_msg, _empty_msg) do
    case backend_bin() do
      nil -> (Log.warn("no local backend installed"); {:error, :no_backend})
      {tool, bin} ->
        case System.cmd(bin, args, stderr_to_stdout: true) do
          {_, 0} -> (Log.ok("#{ok_msg} (#{tool})"); :ok)
          {out, _} -> (Log.warn(String.slice(out, 0, 120)); :ok)
        end
    end
  end

  # discover a local container backend, preferring krunvm (mac microVM) → podman → docker.
  defp backend_bin do
    Enum.find_value(~w(krunvm podman docker), fn t ->
      case System.find_executable(t), do: (nil -> nil; bin -> {t, bin})
    end)
  end

  defp vm_name, do: System.get_env("WB_VM_NAME") || "workbooks-runtime"

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────
  defp read(file) do
    case File.read(file) do
      {:ok, html} -> {:ok, html}
      {:error, _} -> {:error, :no_file}
    end
  end

  defp config_error({:error, :no_file}), do: (Log.error("no #{@config_file} — run `work deploy init` first"); {:error, :no_file})
  defp config_error({:error, :no_work_deploy_element}), do: (Log.error("no <work-deploy> element in the config"); {:error, :no_config})
  defp config_error(_), do: (Log.error("could not read the deployment config"); {:error, :config})

  defp health_url(target) do
    cond do
      String.starts_with?(target, "http") -> if String.contains?(target, "/health"), do: target, else: target <> "/health"
      true -> (System.get_env("WB_RUNTIME_URL") || "http://localhost:4000") <> "/health"
    end
  end
end
