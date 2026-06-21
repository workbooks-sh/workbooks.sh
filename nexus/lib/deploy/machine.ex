defmodule Nexus.Deploy.Machine do
  @moduledoc """
  The local MACHINE — boots + runs the ONE nexus OCI image on the user's box. This is the layer
  OUTSIDE the engine; nexus's own wasmtime sandbox (where untrusted unit code runs) is a separate,
  inner boundary — don't conflate them. On macOS the machine is a libkrun microVM driven by the
  `krunvm` tool — the mac arm of the cross-platform seam (podman/docker/WSL2 slot in elsewhere
  behind the same contract: preflight → create → run → status → down). Proven contract (krunvm 0.2.6):

    * needs a case-sensitive APFS volume named `krunvm` (one-time, no sudo)
    * `krunvm create <image> --name N --port H:G --volume H:G`
    * `krunvm start N -- <cmd>` runs the microVM in the FOREGROUND
    * `krunvm delete N` / `krunvm list`

  Ported faithfully from the runtime's `Workbooks.Deploy.Machine` (the run logic we keep). It runs
  `/app/bin/nexus` from a nexus release. The OCI image is built + published by CI
  (`.github/workflows/nexus-image.yml` → `ghcr.io/workbooks-sh/runtime:latest`, pullable), so
  `local/1` has an image to boot; `mix nexus.deploy.local` defaults to it (the `work deploy apply`
  local bridge).
  """
  @vm "nexus-runtime"
  @guest_port 4000
  # Boot the app with NO TTY console (release `start` blocks on a TTY under krunvm), then park the
  # node alive so the VM stays up; halt non-zero on failure so it surfaces in logs.
  @boot_expr ~S|case Application.ensure_all_started(:nexus) do {:ok, _} -> Process.sleep(:infinity); err -> IO.inspect(err); System.halt(1) end|

  @doc "Backend availability + the one-time prerequisite (the case-sensitive volume)."
  def preflight do
    cond do
      sh("command", ["-v", "krunvm"]) == :error -> {:error, :krunvm_missing, "krunvm not installed — `brew tap slp/krun && brew install krunvm`"}
      not apfs_volume?() -> {:error, :apfs_volume_missing, "case-sensitive APFS volume 'krunvm' missing — run `#{apfs_create_cmd()}` (no sudo, non-destructive)"}
      true -> :ok
    end
  end

  @doc "Create the one-time case-sensitive APFS volume krunvm needs for its OCI store."
  def ensure_apfs_volume do
    if apfs_volume?() do
      :ok
    else
      case sh("diskutil", ["apfs", "addVolume", apfs_container(), "Case-sensitive APFS", "krunvm"]) do
        {:ok, _} -> :ok
        {:error, out} -> {:error, "could not create APFS volume: #{out}"}
      end
    end
  end

  @doc """
  (Re)create the microVM from `image`, mapping `host_port`→guest 4000 and the data dir → /data.
  Idempotent: deletes any existing VM of the same name first so config changes actually take.
  """
  def create(image, opts \\ []) do
    host_port = Keyword.get(opts, :host_port, @guest_port)
    data = Keyword.get(opts, :data_dir, default_data_dir())
    File.mkdir_p!(data)

    _ = sh("krunvm", ["delete", @vm])

    args =
      [
        "create", image,
        "--name", @vm,
        "--cpus", to_string(Keyword.get(opts, :cpus, 2)),
        "--mem", to_string(Keyword.get(opts, :mem_mib, 2048)),
        "--workdir", "/app",
        "--port", "#{host_port}:#{@guest_port}",
        "--volume", "#{data}:/data"
      ]

    case sh("krunvm", args) do
      {:ok, _} -> {:ok, %{vm: @vm, host_port: host_port, url: "http://127.0.0.1:#{host_port}", data_dir: data}}
      {:error, out} -> {:error, out}
    end
  end

  @doc "The foreground argv that boots the microVM (env injected via `krunvm start --env`)."
  def start_argv(env \\ %{}) do
    envs =
      env
      |> Map.merge(%{"WB_DATA" => "/data"})
      |> Enum.flat_map(fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    # Boot via `eval` + sleep (NOT `bin/nexus start` — the release `start` console needs a TTY the
    # krunvm guest doesn't have). krunvm execs this argv directly (no shell), so the expr is one arg.
    ["krunvm", "start", @vm] ++ envs ++ ["--", "/app/bin/nexus", "eval", @boot_expr]
  end

  @doc "Is the microVM defined in krunvm's store?"
  def exists? do
    case sh("krunvm", ["list"]) do
      {:ok, out} -> String.contains?(out, @vm)
      _ -> false
    end
  end

  @doc "Delete the microVM (leaves the APFS volume + image store intact)."
  def delete, do: sh("krunvm", ["delete", @vm])

  @doc """
  Spawn the microVM DIRECTLY in the caller's session (detached) — macOS virtualization (libkrun)
  needs the user's GUI/Aqua session, so a background LaunchAgent fails (EX_CONFIG). Survives the
  caller quitting (reparented); a full logout ends it. Writes the pid to a pidfile for `down`.
  """
  def spawn_direct(env \\ %{}) do
    argv = start_argv(env)
    File.mkdir_p!(log_dir())
    out = Path.join(log_dir(), "runtime.out.log")
    err = Path.join(log_dir(), "runtime.err.log")
    cmd = argv |> Enum.map(&shquote/1) |> Enum.join(" ")
    script = "nohup #{cmd} >> #{shquote(out)} 2>> #{shquote(err)} & echo $! > #{shquote(pidfile())}"

    case sh("sh", ["-c", script]) do
      {:ok, _} -> {:ok, %{pid: read_pidfile(), agent: :direct}}
      {:error, m} -> {:error, m}
      :error -> {:error, "could not spawn krunvm (sh failed)"}
    end
  end

  @doc "Kill the directly-spawned microVM process (if any)."
  def kill_direct do
    case read_pidfile() do
      nil -> :ok
      pid -> _ = sh("kill", [to_string(pid)]); _ = File.rm(pidfile()); :ok
    end
  end

  @doc "Stop the running microVM (direct-spawn pid) and remove it."
  def down do
    _ = kill_direct()
    delete()
  end

  defp log_dir, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.nexus", "logs"])
  defp pidfile, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.nexus", "runtime.pid"])

  defp read_pidfile do
    with {:ok, s} <- File.read(pidfile()), {n, _} <- Integer.parse(String.trim(s)) do
      n
    else
      _ -> nil
    end
  end

  defp shquote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp default_data_dir, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.nexus", "data"])

  defp apfs_volume?, do: File.dir?("/Volumes/krunvm") or String.contains?(elem_ok(sh("diskutil", ["list"])), "krunvm")
  defp apfs_container, do: (sh("diskutil", ["info", "/"]) |> elem_ok() |> grep_after("APFS Container:")) || "disk3"
  defp apfs_create_cmd, do: "diskutil apfs addVolume #{apfs_container()} \"Case-sensitive APFS\" krunvm"

  defp grep_after(text, key) do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, key, parts: 2) do
        [_, rest] -> rest |> String.trim() |> String.split() |> List.first()
        _ -> nil
      end
    end)
  end

  defp elem_ok({:ok, out}), do: out
  defp elem_ok(_), do: ""

  # Run a command, capturing combined output. {:ok, out} | {:error, out} | :error (missing).
  defp sh(cmd, args) do
    {out, code} = System.cmd(cmd, args, stderr_to_stdout: true)
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    ErlangError -> :error
  end
end
