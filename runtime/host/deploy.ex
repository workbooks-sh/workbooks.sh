defmodule Workbooks.Deploy do
  @moduledoc """
  The deploy-kit — stand up the ONE runtime OCI image, locally or on a cloud
  machine. Radically simpler than the legacy multi-cell kit: there is one image
  and two places to run it.

    * `local` — the same image in a local Linux container (krunvm/libkrun on mac),
      managed by a launchd LaunchAgent so it runs on login + survives app quit.
      This is the desktop "daemon"; the Tauri shell drives it. Gives cloud-
      identical isolation (bwrap needs Linux namespaces, absent on bare macOS).
    * `cloud` — the same image on one machine (generic; not fly-locked).

  Backends sit behind a seam (`Workbooks.Deploy.Krunvm` today; podman/docker/WSL2
  later) so the model is cross-platform even though mac ships first. Reached via
  `wb deploy <local|status|down|logs>`.
  """
  alias Workbooks.Deploy.Krunvm

  @default_image "ghcr.io/workbooks-sh/runtime:latest"

  @doc "Bring up the local containerized runtime daemon. Idempotent (converges)."
  def local(opts \\ []) do
    image = Keyword.get(opts, :image, System.get_env("WB_IMAGE", @default_image))
    host_port = Keyword.get(opts, :host_port, free_host_port())

    with :ok <- ensure_prereqs(),
         {:ok, info} <- Krunvm.create(image, host_port: host_port),
         {:ok, _} <- Krunvm.install_agent(%{}) do
      case await_discovery(15_000) do
        {:ok, disc} ->
          {:ok,
           """
           local runtime up — #{info.url}
             token:   #{String.slice(disc["token"] || "", 0, 8)}… (in #{Path.join(info.disco_dir, "runtime.json")})
             data:    #{info.data_dir}
             agent:   #{Krunvm.label()} (launchd — runs on login, survives app quit)
           stop with `wb deploy down`.
           """}

        {:error, :timeout} ->
          {:ok, "VM + agent installed (#{info.url}) but no discovery yet — check `wb deploy logs`. The image may still be booting or missing (`WB_IMAGE`)."}
      end
    end
  end

  @doc "Report local daemon state: VM presence, launchd, and the discovery file."
  def status do
    vm = if Krunvm.exists?(), do: "present", else: "absent"

    disc =
      case Krunvm.discovery() do
        {:ok, d} -> "up — http://127.0.0.1:#{d["port"]} (pid #{d["pid"]})"
        _ -> "no discovery file"
      end

    {:ok, "local runtime:\n  microVM: #{vm}\n  runtime: #{disc}\n  agent:   #{Krunvm.label()}"}
  end

  @doc "Tear down the local daemon (launchd agent + microVM; keeps data + APFS volume)."
  def down do
    Krunvm.down()
    {:ok, "local runtime down (data + APFS volume preserved)"}
  end

  @doc "Where to look for daemon logs."
  def logs do
    dir = Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "logs"])
    {:ok, "tail -f #{Path.join(dir, "runtime.err.log")} #{Path.join(dir, "runtime.out.log")}"}
  end

  # ---- internals -------------------------------------------------------------
  defp ensure_prereqs do
    case Krunvm.preflight() do
      :ok -> :ok
      {:error, :apfs_volume_missing, _} -> Krunvm.ensure_apfs_volume()
      {:error, _, msg} -> {:error, msg}
    end
  end

  defp await_discovery(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(deadline)
  end

  defp do_await(deadline) do
    case Krunvm.discovery() do
      {:ok, d} -> {:ok, d}
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(500)
          do_await(deadline)
        else
          {:error, :timeout}
        end
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
