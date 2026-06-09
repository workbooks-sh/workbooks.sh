defmodule Workbooks.CLI.Desktop do
  @moduledoc """
  `wb desktop` — install + launch the Workbooks DESKTOP app from the CLI. The
  desktop app is the GUI shell whose first-run wizard connects an engine (a local
  microVM via krunvm, or a cloud engine). This is the terminal on-ramp to the
  same artifact you'd download from GitHub Releases.

  HOST-side (shells out, no app/runtime boot — like `wb deploy`). `install`
  dogfoods the SAME `install.sh` served at workbooks.sh, so there is ONE source
  of install truth: the CLI is a thin wrapper, not a second implementation.
  """
  @default_url "https://workbooks.sh/install.sh"

  @doc "Dispatch a `wb desktop` verb → {output, failed?}."
  def run(rest) do
    case rest do
      [] -> {usage(), false}
      ["help" | _] -> {usage(), false}
      ["install" | opts] -> install(opts)
      [v | _] when v in ["open", "launch", "run"] -> launch()
      other -> {"unknown verb: wb desktop #{Enum.join(other, " ")}\n\n#{usage()}", true}
    end
  end

  # Pipe the canonical installer through sh, passing a pinned version via the
  # same WB_VERSION env the script reads. Streams the script's own progress.
  defp install(opts) do
    url = System.get_env("WB_INSTALL_URL") || @default_url
    env = version_env(opts)
    cmd = "curl -fsSL #{shquote(url)} | sh"

    case sh(cmd, env) do
      {out, 0} -> {out, false}
      {out, _code} -> {out, true}
    end
  end

  # Launch the installed app. mac: by app name (resolves in /Applications or
  # ~/Applications); linux: the `workbooks` binary the installer drops on PATH.
  defp launch do
    case :os.type() do
      {:unix, :darwin} ->
        case sh("open -a Workbooks", []) do
          {_out, 0} -> {"launched Workbooks", false}
          {out, _} -> {"could not launch Workbooks — install it first with `wb desktop install`.\n#{out}", true}
        end

      {:unix, _} ->
        case sh("workbooks >/dev/null 2>&1 &", []) do
          {_out, 0} -> {"launched workbooks", false}
          {out, _} -> {"could not launch — is it on PATH? Install with `wb desktop install`.\n#{out}", true}
        end

      _ ->
        {"`wb desktop open` isn't supported on this OS — launch the app from your applications menu.", true}
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
    wb desktop — install + launch the Workbooks desktop app.

      wb desktop install                install the latest release (curl | sh)
      wb desktop install --version=X    pin a release (tag desktop-vX)
      wb desktop open                   launch the installed app

    The installer downloads the app from GitHub Releases; the app's own first-run
    wizard connects an engine (local microVM or cloud) — it's optional, the app
    runs offline without one. Override the installer URL with WB_INSTALL_URL.
    """
  end
end
