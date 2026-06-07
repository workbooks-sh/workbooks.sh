defmodule Workbooks.Deploy do
  @moduledoc """
  The deploy-kit — stand up the ONE runtime OCI image, locally or on a cloud
  machine. Radically simpler than the legacy multi-cell kit: one image, two places.

    * `local` — the same image in a local Linux container (krunvm/libkrun on mac),
      managed by a launchd LaunchAgent so it runs on login + survives app quit.
      The desktop "daemon"; the Tauri shell drives it. Cloud-identical isolation
      (bwrap needs Linux namespaces, absent on bare macOS).
    * `cloud` — the same image on one machine (generic; not fly-locked).

  Built for AGENTS as much as humans: every verb is non-interactive, idempotent,
  returns a tagged `{:ok | :error, map}` (rendered human OR `--json`), and exits
  non-zero on failure. `doctor` self-heals prereqs; `verify` proves the LIVE
  runtime answers. Backends sit behind a seam (`Krunvm` today; podman/docker/WSL2
  later). Reached via `wb deploy <verb> [--json]`.
  """
  alias Workbooks.Deploy.{Krunvm, Image, Backend, Config}

  @doc "Coherence-check a deployment.org without deploying (the write-then-submit gate)."
  def validate(file) do
    with {:ok, p} <- Config.parse(file) do
      case Config.validate(p) do
        :ok -> ok("valid — #{Config.summary(p)}", %{valid: true})
        {:error, issues} -> err("invalid deployment:\n  - " <> Enum.join(issues, "\n  - "), %{valid: false, issues: issues})
      end
    else
      {:error, msg} -> err(msg, %{})
    end
  end

  @doc """
  Apply a `deployment.org`: validate, then converge to it. ENGINE_PLACE picks the
  target (local krunvm vs the cloud provider); TENANCY_MODE + the BYOD STORAGE/
  DATABASE axes + PROFILE flow to the engine as env. Idempotent.
  """
  def apply(file) do
    with {:ok, p} <- Config.parse(file),
         :ok <- coherent(p) do
      env = Config.to_env(p)

      case Config.place(p) do
        "local" -> local(env: env)
        "cloud" -> cloud_apply(p, env)
        other -> err("ENGINE_PLACE must be local|cloud (got #{inspect(other)})", %{})
      end
    else
      {:error, issues} when is_list(issues) -> err("invalid deployment:\n  - " <> Enum.join(issues, "\n  - "), %{issues: issues})
      {:error, msg} -> err(msg, %{})
    end
  end

  defp coherent(p) do
    case Config.validate(p), do: (:ok -> :ok; {:error, issues} -> {:error, issues})
  end

  # Cloud is one concept; the provider is config (PROVIDER, default fly) — the
  # extension point, not a user-facing menu. The config env becomes the engine's.
  defp cloud_apply(p, env) do
    provider = Config.provider(p)

    case Backend.resolve(provider) do
      {:provider, _pl, boot} ->
        case Backend.run_provider(boot, "up", Map.put(env, "WB_IMAGE", Image.ref())) do
          {:ok, out} -> ok("cloud deploy (#{provider}) — #{Config.summary(p)}:\n#{String.trim_trailing(out)}", %{provider: provider})
          {:error, out} -> err("cloud deploy (#{provider}) failed:\n#{String.trim_trailing(out)}", %{provider: provider})
        end

      _ ->
        err("cloud PROVIDER=#{provider} has no recipe at deploy/providers/#{provider}", %{provider: provider})
    end
  end

  @doc "Check + self-heal prerequisites (idempotent). The first thing an agent runs."
  def doctor do
    case Krunvm.preflight() do
      :ok ->
        ok("prereqs OK", %{krunvm: true, apfs_volume: true})

      {:error, :apfs_volume_missing, _} ->
        case Krunvm.ensure_apfs_volume() do
          :ok -> ok("created the case-sensitive APFS volume; prereqs OK now", %{krunvm: true, apfs_volume: :created})
          {:error, m} -> err(m, %{krunvm: true, apfs_volume: false})
        end

      {:error, reason, msg} ->
        err(msg, %{reason: reason})
    end
  end

  @doc "Bring up the local containerized runtime daemon. Idempotent (converges)."
  def local(opts \\ []) do
    image = Keyword.get(opts, :image, Image.ref())
    env = Keyword.get(opts, :env, %{})
    host_port = Keyword.get(opts, :host_port, free_host_port())

    with {:ok, _, _} <- doctor(),
         {:ok, info} <- Krunvm.create(image, host_port: host_port),
         {:ok, _} <- Krunvm.install_agent(env) do
      base = %{url: info.url, image: image, data_dir: info.data_dir, agent: Krunvm.label()}

      case await_discovery(15_000) do
        {:ok, disc} ->
          ok("local runtime up — #{info.url} (runs on login, survives app quit; `wb deploy down` to stop)",
             Map.merge(base, %{state: "up", token_preview: String.slice(disc["token"] || "", 0, 8)}))

        {:error, :timeout} ->
          ok("VM + agent installed (#{info.url}) but no discovery yet — `wb deploy logs`/`verify`. Image may still be booting.",
             Map.merge(base, %{state: "starting"}))
      end
    else
      {:error, msg, data} -> err(msg, data)
      {:error, msg} -> err(msg, %{})
    end
  end

  @doc "Report local daemon state: VM presence, launchd, the discovery file."
  def status do
    vm? = Krunvm.exists?()

    {runtime, fields} =
      case Krunvm.discovery() do
        {:ok, d} -> {"up — http://127.0.0.1:#{d["port"]} (pid #{d["pid"]})", %{state: "up", port: d["port"], pid: d["pid"]}}
        _ -> {"no discovery file", %{state: "down"}}
      end

    ok("local runtime: microVM #{if(vm?, do: "present", else: "absent")}; runtime #{runtime}",
       Map.merge(fields, %{microvm: vm?, agent: Krunvm.label()}))
  end

  @doc "Prove the LIVE runtime answers (not just that config is valid). Non-zero if not."
  def verify do
    with {:ok, d} <- Krunvm.discovery(),
         port when is_integer(port) <- d["port"],
         {:ok, status, body} <- http_get("http://127.0.0.1:#{port}/health", d["token"]) do
      if status == 200 and String.contains?(body, "ok"),
        do: ok("runtime healthy — http://127.0.0.1:#{port}/health → 200", %{state: "healthy", port: port}),
        else: err("runtime reachable but unhealthy (HTTP #{status})", %{state: "unhealthy", port: port, http: status})
    else
      {:error, :no_discovery} -> err("no discovery file — is the daemon up? `wb deploy local`", %{state: "down"})
      {:error, reason} -> err("runtime not reachable: #{inspect(reason)}", %{state: "unreachable"})
      _ -> err("runtime not reachable", %{state: "unreachable"})
    end
  end

  @doc "Tear down the local daemon (launchd agent + microVM; keeps data + APFS volume). Idempotent."
  def down do
    Krunvm.down()
    ok("local runtime down (data + APFS volume preserved)", %{state: "down"})
  end

  @doc "Where to look for daemon logs."
  def logs do
    dir = Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "logs"])
    out = Path.join(dir, "runtime.out.log")
    err_log = Path.join(dir, "runtime.err.log")
    ok("tail -f #{err_log} #{out}", %{stdout: out, stderr: err_log})
  end

  @doc "Render a tagged result for the CLI — `--json` → machine map, else the message."
  def render({tag, msg, data}, json?) do
    if json?,
      do: Jason.encode!(Map.merge(%{ok: tag == :ok, message: msg}, data)),
      else: if(tag == :ok, do: msg, else: "deploy error: #{msg}")
  end

  @doc "Did a verb fail? (drives the CLI exit code.)"
  def failed?({:error, _, _}), do: true
  def failed?(_), do: false

  # ---- internals -------------------------------------------------------------
  defp ok(msg, data), do: {:ok, msg, data}
  defp err(msg, data), do: {:error, msg, data}

  defp await_discovery(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(deadline)
  end

  defp do_await(deadline) do
    case Krunvm.discovery() do
      {:ok, d} ->
        {:ok, d}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_await(deadline)
        else
          {:error, :timeout}
        end
    end
  end

  defp http_get(url, token) do
    :inets.start()
    :ssl.start()
    headers = if token, do: [{~c"authorization", String.to_charlist("Bearer " <> token)}], else: []

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  # A free localhost port for the host→guest map (the guest always binds 4000).
  defp free_host_port do
    {:ok, s} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    p
  end
end
