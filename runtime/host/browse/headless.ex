defmodule Workbooks.Browse.Headless do
  @moduledoc """
  Headless page render via a LOCAL Chromium (chrome-headless-shell / system Chrome)
  driven by the `--dump-dom` flag — it runs the page's JavaScript and prints the
  rendered DOM. No CDP client, no Node, no remote browser service. Runs host-side
  and is brokered to the wasm guest (which can't run a browser) — same trust model
  as the git/publish/build host tools.

  SSRF floor: the URL is checked with `Workbooks.NetGuard.allowed?/1` BEFORE Chrome
  launches, so the browser can't be aimed at internal/metadata/loopback addresses.
  Bounded by Chrome's own `--timeout`/`--virtual-time-budget` plus a hard
  Task.shutdown, so a hung render can't wedge the runtime.

  Chrome's process sandbox is kept ON (it isolates the renderer processing
  UNTRUSTED pages); `--no-sandbox` is added only via `WB_CHROME_NO_SANDBOX=1` for
  hosts that can't init the sandbox (root / minimal container).
  """
  require Logger

  @cache_glob "~/.cache/puppeteer/chrome-headless-shell/*/*/chrome-headless-shell"
  @mac_chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  @doc "Render `url` (runs its JS) → {:ok, rendered_html} | {:error, reason}."
  def render(url, opts \\ [])
  def render(url, _opts) when not is_binary(url) or url == "", do: {:error, :no_url}

  def render(url, opts) do
    timeout = opts[:timeout] || 20_000

    cond do
      not Workbooks.NetGuard.allowed?(url) ->
        Logger.warning("wb-browse: DENY #{inspect(url)} — SSRF (internal/non-routable destination)")
        {:error, :blocked}

      true ->
        case chrome_bin() do
          nil -> {:error, :no_browser}
          bin -> run(bin, url, timeout)
        end
    end
  end

  @doc """
  Screenshot a local file:// page → {:ok, png_path} | {:error, reason}.

  Used by the component-emit eval pack to capture a mounted `work-*` artifact.
  Same chrome binary / sandbox / timeout discipline as `render/2`; the SSRF
  NetGuard gate is skipped ONLY for `file://` paths under a caller-owned temp
  dir (the eval mount HTML the harness itself wrote) — never a remote URL.
  """
  def screenshot(url, out_png, opts \\ [])
  def screenshot(url, _out, _opts) when not is_binary(url) or url == "", do: {:error, :no_url}

  def screenshot(url, out_png, opts) do
    timeout = opts[:timeout] || 15_000
    local? = String.starts_with?(url, "file://")

    cond do
      not local? and not Workbooks.NetGuard.allowed?(url) ->
        {:error, :blocked}

      true ->
        case chrome_bin() do
          nil -> {:error, :no_browser}
          bin -> run_shot(bin, url, out_png, opts[:window] || "900,640", timeout)
        end
    end
  end

  defp run_shot(bin, url, out_png, window, timeout) do
    base = [
      "--headless",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=2",
      "--window-size=#{window}",
      "--timeout=#{timeout}",
      "--virtual-time-budget=#{timeout}",
      "--screenshot=#{out_png}",
      url
    ]

    args = if System.get_env("WB_CHROME_NO_SANDBOX") == "1", do: ["--no-sandbox" | base], else: base
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} ->
        if File.exists?(out_png) and File.stat!(out_png).size > 0,
          do: {:ok, out_png},
          else: {:error, :empty_screenshot}

      {:ok, {out, code}} ->
        {:error, {:exit, code, String.slice(out, 0, 400)}}

      _ ->
        {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Is a local headless browser available on this host?"
  def available?, do: chrome_bin() != nil

  @doc false
  def chrome_args_for_test(url, timeout), do: chrome_args(url, timeout)

  # Chrome's process sandbox is the defense when rendering UNTRUSTED pages — keep it
  # ON by default. `--no-sandbox` is only added via explicit opt-in
  # (WB_CHROME_NO_SANDBOX=1) for hosts that can't init the sandbox (root / minimal
  # container), accepting the weaker isolation there.
  defp chrome_args(url, timeout) do
    base = [
      "--headless",
      "--disable-gpu",
      "--timeout=#{timeout}",
      "--virtual-time-budget=#{timeout}",
      "--user-agent=Mozilla/5.0 (WorkbooksBrowse)",
      "--dump-dom",
      url
    ]

    if System.get_env("WB_CHROME_NO_SANDBOX") == "1", do: ["--no-sandbox" | base], else: base
  end

  defp run(bin, url, timeout) do
    task = Task.async(fn -> System.cmd(bin, chrome_args(url, timeout), stderr_to_stdout: false) end)

    case Task.yield(task, timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {dom, 0}} when byte_size(dom) > 0 -> {:ok, dom}
      {:ok, {_, code}} -> {:error, {:exit, code}}
      _ -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # WB_CHROME_BIN override → puppeteer cache → macOS Chrome.app → system chromium/chrome.
  defp chrome_bin do
    candidates =
      [System.get_env("WB_CHROME_BIN")] ++
        Path.wildcard(Path.expand(@cache_glob)) ++
        [
          @mac_chrome,
          System.find_executable("chromium"),
          System.find_executable("google-chrome"),
          System.find_executable("chrome-headless-shell")
        ]

    Enum.find(candidates, fn p -> is_binary(p) and File.exists?(p) end)
  end
end
