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

  @doc "Is a local headless browser available on this host?"
  def available?, do: chrome_bin() != nil

  defp run(bin, url, timeout) do
    args = [
      "--headless",
      "--disable-gpu",
      "--no-sandbox",
      "--timeout=#{timeout}",
      "--virtual-time-budget=#{timeout}",
      "--user-agent=Mozilla/5.0 (WorkbooksBrowse)",
      "--dump-dom",
      url
    ]

    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: false) end)

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
