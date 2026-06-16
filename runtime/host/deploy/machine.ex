defmodule Workbooks.Deploy.Machine do
  @moduledoc """
  The local MACHINE — boots + runs the ONE runtime OCI image on the user's box. This is the
  layer OUTSIDE the engine; the engine's own wasmtime sandbox (where untrusted code runs) is a
  separate, inner boundary — don't conflate them. On macOS the machine is a libkrun microVM
  driven by the `krunvm` tool — the mac arm of the cross-platform seam (podman/docker/WSL2 slot
  in elsewhere behind the same contract: ensure → create → run → status → down). Proven
  contract (krunvm 0.2.6):

    * needs a case-sensitive APFS volume named `krunvm` (one-time, no sudo)
    * `krunvm create <image> --name N --port H:G --volume H:G`
    * `krunvm start N -- <cmd>` runs the microVM in the FOREGROUND (launchd-managed)
    * `krunvm delete N` / `krunvm list`

  The runtime inside binds 0.0.0.0:GUEST_PORT and writes the discovery file to a
  bind-mounted dir (see `Workbooks.Desktop`); the host maps HOST_PORT→GUEST_PORT.
  """
  @vm "workbooks-runtime"
  @guest_port 4000
  @label "sh.workbooks.runtime"
  # Start the app with NO TTY console (release `start` blocks on a TTY under
  # krunvm), then park the node alive so the VM stays up; halt non-zero on failure
  # so it surfaces in `work deploy logs` instead of hanging.
  @boot_expr ~S|case Application.ensure_all_started(:workbooks) do {:ok, _} -> Process.sleep(:infinity); err -> IO.inspect(err); System.halt(1) end|

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
  (Re)create the microVM from `image`, mapping `host_port`→guest 4000, the data
  dir → /data, and the discovery dir → /disco. Idempotent: deletes any existing
  VM of the same name first so config changes (ports/volumes) actually take.
  """
  def create(image, opts \\ []) do
    host_port = Keyword.get(opts, :host_port, @guest_port)
    data = Keyword.get(opts, :data_dir, default_data_dir())
    disco = Keyword.get(opts, :disco_dir, default_disco_dir())
    File.mkdir_p!(data)
    File.mkdir_p!(disco)

    _ = sh("krunvm", ["delete", @vm])

    args =
      [
        "create", image,
        "--name", @vm,
        "--cpus", to_string(Keyword.get(opts, :cpus, 2)),
        "--mem", to_string(Keyword.get(opts, :mem_mib, 2048)),
        # The runtime image's WORKDIR — krunvm doesn't inherit it, so set it
        # explicitly or a relative entrypoint runs from `/` and fails.
        "--workdir", "/app",
        "--port", "#{host_port}:#{@guest_port}",
        "--volume", "#{data}:/data",
        "--volume", "#{disco}:/disco"
      ]

    case sh("krunvm", args) do
      {:ok, _} -> {:ok, %{vm: @vm, host_port: host_port, url: "http://127.0.0.1:#{host_port}", data_dir: data, disco_dir: disco}}
      {:error, out} -> {:error, out}
    end
  end

  @doc """
  The foreground command launchd runs to boot the microVM. Env is injected via
  `krunvm start --env`; WB_DESKTOP=1 puts the runtime in daemon mode and
  WB_DESKTOP_DIR=/disco lands the discovery file in the bind-mounted host dir.
  """
  def start_argv(env \\ %{}) do
    envs =
      env
      |> Map.merge(%{"WB_DESKTOP" => "1", "WB_DESKTOP_DIR" => "/disco", "WB_DATA" => "/data", "WB_EMBED" => "local"})
      |> Enum.flat_map(fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    # Boot via `eval` + sleep, NOT `bin/workbooks start`. The release `start`
    # command runs a FOREGROUND console that needs a TTY; under krunvm's no-TTY
    # guest it blocks at console init before the app boots (silent, no discovery).
    # `eval` boots the app with no console, then we park the node alive so the VM
    # stays up. krunvm execs this argv directly (no shell), so the expr is one arg.
    ["krunvm", "start", @vm] ++ envs ++ ["--", "/app/bin/workbooks", "eval", @boot_expr]
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

  # ---- launchd LaunchAgent (runs on login, KeepAlive, survives app quit) ------
  def label, do: @label
  def plist_path, do: Path.join([System.user_home!(), "Library", "LaunchAgents", "#{@label}.plist"])

  @doc "Render the LaunchAgent plist that runs `krunvm start …` as the daemon."
  def plist(env \\ %{}) do
    [_cmd | _] = argv = start_argv(env)
    program_args = argv |> Enum.map(&"    <string>#{xml(&1)}</string>") |> Enum.join("\n")
    logdir = Path.join(default_disco_dir() |> Path.dirname(), "logs")
    File.mkdir_p!(logdir)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
    #{program_args}
      </array>
      <key>EnvironmentVariables</key>
      <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>#{Path.join(logdir, "runtime.out.log")}</string>
      <key>StandardErrorPath</key><string>#{Path.join(logdir, "runtime.err.log")}</string>
    </dict>
    </plist>
    """
  end

  @doc "Install + bootstrap the LaunchAgent (idempotent)."
  def install_agent(env \\ %{}) do
    path = plist_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, plist(env))
    domain = "gui/#{uid()}"
    _ = sh("launchctl", ["bootout", domain, path])
    sh("launchctl", ["bootstrap", domain, path])
  end

  @doc """
  Spawn the microVM DIRECTLY in the CALLER's session (detached), instead of via a
  launchd LaunchAgent. macOS virtualization (libkrun) needs the user's GUI/Aqua
  session — a background LaunchAgent fails with EX_CONFIG (exit 78). The desktop
  app lives in the Aqua session and shells out to `work deploy local`, so the krunvm
  we background here inherits that session and boots cleanly. It survives the app
  quitting (reparented, not a child of the app); a full logout ends it — use
  `install_agent/1` for start-on-login. Writes the pid to a pidfile for `down`.
  """
  def spawn_direct(env \\ %{}) do
    argv = start_argv(env)
    File.mkdir_p!(log_dir())
    out = Path.join(log_dir(), "runtime.out.log")
    err = Path.join(log_dir(), "runtime.err.log")
    cmd = argv |> Enum.map(&shquote/1) |> Enum.join(" ")
    # nohup + & detaches krunvm from this escript; `echo $!` records its pid.
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

  @doc "Stop + remove BOTH lifecycles (direct-spawn pid + any LaunchAgent) and the microVM."
  def down do
    domain = "gui/#{uid()}"
    _ = sh("launchctl", ["bootout", domain, plist_path()])
    _ = File.rm(plist_path())
    _ = kill_direct()
    delete()
  end

  defp log_dir, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "logs"])
  defp pidfile, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "runtime.pid"])

  defp read_pidfile do
    with {:ok, s} <- File.read(pidfile()), {n, _} <- Integer.parse(String.trim(s)) do
      n
    else
      _ -> nil
    end
  end

  # POSIX single-quote: wrap in '...' and escape embedded quotes as '\''.
  defp shquote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @doc "Read the discovery file the runtime wrote into the bind-mounted disco dir."
  def discovery do
    path = Path.join(default_disco_dir(), "runtime.json")

    with {:ok, body} <- File.read(path), {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _ -> {:error, :no_discovery}
    end
  end

  # ---- helpers ---------------------------------------------------------------
  defp default_data_dir, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "data"])
  defp default_disco_dir, do: Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks", "disco"])

  defp apfs_volume?, do: File.dir?("/Volumes/krunvm") or String.contains?(elem_ok(sh("diskutil", ["list"])), "krunvm")
  defp apfs_container, do: (sh("diskutil", ["info", "/"]) |> elem_ok() |> grep_after("APFS Container:")) || "disk3"
  defp apfs_create_cmd, do: "diskutil apfs addVolume #{apfs_container()} \"Case-sensitive APFS\" krunvm"

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

  defp xml(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

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

  # Run a command, capturing combined output. Returns {:ok, out} | {:error, out} | :error (missing).
  defp sh(cmd, args) do
    {out, code} = System.cmd(cmd, args, stderr_to_stdout: true)
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    ErlangError -> :error
  end
end
