defmodule Workbooks.CLI.Desktop do
  @moduledoc """
  `work desktop` — install + launch the Workbooks DESKTOP app from the CLI. The
  desktop app is the GUI shell whose first-run wizard connects an engine (a local
  microVM via krunvm, or a cloud engine). This is the terminal on-ramp to the
  same artifact you'd download from GitHub Releases.

  HOST-side (shells out, no app/runtime boot — like `work deploy`). `install`
  dogfoods the SAME `install.sh` served at workbooks.sh, so there is ONE source
  of install truth: the CLI is a thin wrapper, not a second implementation.
  """
  @default_url "https://workbooks.sh/install.sh"

  @doc "Dispatch a `work desktop` verb → {output, failed?}."
  def run(rest) do
    case rest do
      [] -> {usage(), false}
      ["help" | _] -> {usage(), false}
      ["install" | opts] -> install(opts)
      [v | rest2] when v in ["open", "launch", "run"] -> open(rest2)
      ["mcp" | opts] -> mcp(opts)
      other -> {"unknown verb: work desktop #{Enum.join(other, " ")}\n\n#{usage()}", true}
    end
  end

  # Pipe the canonical installer through sh, passing a pinned version via the
  # same WB_VERSION env the script reads. Streams the script's own progress.
  defp install(opts) do
    url = System.get_env("WB_INSTALL_URL") || @default_url
    env = version_env(opts)
    cmd = "curl -fsSL #{shquote(url)} | sh"

    case sh(cmd, env) do
      {out, 0} ->
        # `work desktop install --open` chains install → launch in one motion,
        # so Claude Code (or the user) lands in the running browser.
        if "--open" in opts do
          {launch_out, failed?} = open([])
          {out <> "\n" <> launch_out, failed?}
        else
          {out, false}
        end

      {out, _code} ->
        {out, true}
    end
  end

  # `work desktop open [<path|url>]`. With no target, just launches/focuses the
  # app. With a target, drops an open-intent file the running (or next-booting)
  # browser picks up and opens as a tab — a dependency-free deep link: no URL
  # scheme to register, no Tauri plugin, works for both a cold start and a
  # second invocation against the live instance. The app reads + clears the
  # intent on boot and on window focus (openIntent.svelte.ts).
  defp open([]), do: launch()

  defp open([target | _]) do
    case write_intent(target) do
      :ok ->
        {launch_out, failed?} = launch()
        {"queued open: #{target}\n#{launch_out}", failed?}

      {:error, reason} ->
        {"could not queue open intent: #{reason}", true}
    end
  end

  # `work desktop mcp` — the MCP on-ramp (wb-aakl.11; server impl wb-aakl.23).
  # No args: print the connection config + the one-line `claude mcp add`.
  # `--stdio`: act as the stdio↔UDS relay Claude Code runs (impl wb-aakl.23).
  @mcp_default_sock "/tmp/workbooks-mcp.sock"
  defp mcp(opts) do
    sock = System.get_env("WB_MCP_SOCK") || @mcp_default_sock

    if "--stdio" in opts do
      # The stdio↔UDS relay Claude Code runs (`claude mcp add workbooks -- wb
      # desktop mcp --stdio`). Connect to the live browser's Unix socket and
      # pump bytes both ways: stdin → socket, socket → stdout. Blocks until
      # either side closes; returns "" so no chatter pollutes the MCP stream.
      stdio_relay(sock)
    else
      running? = File.exists?(sock)

      msg = """
      Workbooks browser — MCP connection

        socket   #{sock}#{if running?, do: " (browser running)", else: " (browser not running — start it first)"}
        enable   set WB_MCP=1 before launching the browser (off by default)

      Add it to Claude Code (one line):

        claude mcp add workbooks -- work desktop mcp --stdio

      The browser exposes workbooks-native tools (tabs, bookmarks, the
      workspace tree, open_workbook, weave/validate via oql.wasm) plus
      generic webview tools (screenshot, dom_read, eval_js, click/type) and
      the Waldo agent bridge. Local Unix socket only — no network listener.
      See desktop/docs/mcp.md.
      """

      {msg, false}
    end
  end

  # stdin ↔ UDS pump. Claude Code speaks MCP over stdio; the browser listens on
  # a Unix socket. We connect with the `:local` address family (OTP 19+), then
  # run two copy loops: a spawned task drains the socket to stdout, the main
  # process drains stdin to the socket. Either EOF/close tears the relay down.
  defp stdio_relay(sock) do
    unless File.exists?(sock) do
      throw_relay("browser not running (no socket at #{sock}). Start it with WB_MCP=1, e.g. `WB_MCP=1 work desktop open`.")
    end

    case :gen_tcp.connect({:local, to_charlist(sock)}, 0, [:binary, active: false, packet: 0]) do
      {:ok, socket} ->
        # Stdin must be raw binary, unbuffered, so JSON-RPC lines flow promptly.
        :ok = :io.setopts(:standard_io, [:binary])

        reader =
          spawn_link(fn ->
            socket_to_stdout(socket)
          end)

        stdin_to_socket(socket, reader)
        {"", false}

      {:error, reason} ->
        {"work desktop mcp --stdio: could not connect to #{sock}: #{inspect(reason)}", true}
    end
  catch
    {:relay_error, msg} -> {msg, true}
  end

  defp throw_relay(msg), do: throw({:relay_error, msg})

  # socket → stdout, until the browser closes the connection.
  defp socket_to_stdout(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        IO.binwrite(:standard_io, data)
        socket_to_stdout(socket)

      {:error, _} ->
        :ok
    end
  end

  # stdin → socket, until Claude Code closes stdin (EOF).
  defp stdin_to_socket(socket, reader) do
    case IO.binread(:standard_io, 4096) do
      :eof ->
        :gen_tcp.close(socket)
        Process.exit(reader, :kill)
        :ok

      {:error, _} ->
        :gen_tcp.close(socket)
        :ok

      data ->
        case :gen_tcp.send(socket, data) do
          :ok -> stdin_to_socket(socket, reader)
          {:error, _} -> :ok
        end
    end
  end

  # Mirror daemon.rs discovery_path/0: WB_DESKTOP_DIR overrides, else the OS
  # data dir + sh.workbooks/disco. Keeps the CLI write-path identical to the
  # path the desktop app reads.
  defp disco_dir do
    case System.get_env("WB_DESKTOP_DIR") do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        base =
          case :os.type() do
            {:unix, :darwin} ->
              Path.join([System.user_home!(), "Library", "Application Support"])

            {:unix, _} ->
              System.get_env("XDG_DATA_HOME") ||
                Path.join(System.user_home!(), ".local/share")

            _ ->
              System.user_home!()
          end

        Path.join([base, "sh.workbooks", "disco"])
    end
  end

  defp write_intent(target) do
    dir = disco_dir()
    payload = Jason.encode!(%{target: to_string(target), ts: System.os_time(:millisecond)})

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "open-intent.json"), payload) do
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Launch the installed app. mac: by app name (resolves in /Applications or
  # ~/Applications); linux: the `workbooks` binary the installer drops on PATH.
  defp launch do
    case :os.type() do
      {:unix, :darwin} ->
        case sh("open -a Workbooks", []) do
          {_out, 0} -> {"launched Workbooks", false}
          {out, _} -> {"could not launch Workbooks — install it first with `work desktop install`.\n#{out}", true}
        end

      {:unix, _} ->
        case sh("workbooks >/dev/null 2>&1 &", []) do
          {_out, 0} -> {"launched workbooks", false}
          {out, _} -> {"could not launch — is it on PATH? Install with `work desktop install`.\n#{out}", true}
        end

      _ ->
        {"`work desktop open` isn't supported on this OS — launch the app from your applications menu.", true}
    end
  end

  defp version_env(opts) do
    case Enum.find_value(opts, fn
           "--version=" <> v -> v
           _ -> nil
         end) do
      nil -> []
      v -> [{"WB_VERSION", v}]
    end
  end

  defp sh(cmd, env), do: System.cmd("sh", ["-c", cmd], env: env, stderr_to_stdout: true)

  defp shquote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp usage do
    """
    work desktop — install + launch the Workbooks browser.

      work desktop install                install the latest release (curl | sh)
      work desktop install --version=X    pin a release (tag desktop-vX)
      work desktop install --open         install, then launch
      work desktop open                   launch the installed browser
      work desktop open <path|url>        open a workbook/page in the browser
      work desktop mcp                    print the MCP config + claude mcp add line

    The installer downloads the browser from GitHub Releases. The runtime is
    installed separately by the CLI; `open <path>` drops an open-intent the
    running browser picks up (no URL scheme needed). Override the installer URL
    with WB_INSTALL_URL; override the app data dir with WB_DESKTOP_DIR.
    """
  end
end
