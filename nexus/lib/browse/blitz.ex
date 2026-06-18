defmodule Nexus.Browse.Blitz do
  @moduledoc """
  The in-wasm render provider — Blitz (Stylo CSS + Taffy layout + Parley text + Vello-CPU paint)
  running in wasmtime. Capabilities `:render` (rendered TEXT, for scraping) + `:screenshot` (PNG).
  The page is fetched host-side (brokered, SSRF-safe via `Nexus.Dock.fetch`); CSS is inlined
  ("freeze") for screenshots so the styled layout renders; then rendered IN the sandbox — no
  Chromium, no native browser, no GPU. No JS yet (SPAs render their server shell; see the browse plan).
  """
  @behaviour Nexus.Browse

  @impl true
  def capabilities, do: [:render, :screenshot]

  # Rendered text. Try the JS renderer (Boa runs the page's scripts against the Blitz DOM); if it
  # crashes or times out (a huge framework bundle can abort the JS engine), FALL BACK to the no-JS
  # render — which still has the server-rendered content (most "SPAs" SSR their text). So scraping is
  # robust: SSR pages always work, JS pages get JS when it runs.
  @impl true
  def render(url, opts) do
    with {:ok, html} <- fetch(url) do
      render_html(html, url, opts)
    end
  end

  @doc """
  Render already-fetched `html` (base `url`) to text — JS-or-SSR-fallback. Lets the navigation layer
  fetch once and render, without a second request.
  """
  def render_html(html, url, opts \\ []) do
    case Keyword.get(opts, :engine, :boa) do
      :auto -> render_html_auto(html, url, opts)
      :jsdom -> render_html_jsdom(html, url, opts)
      _ -> render_html_boa(html, url, opts)
    end
  end

  # Empirically-driven default for "I might need JS": the fast CSS-only render handles SSR sites (most
  # of the web) for a fraction of the compute, and benchmarks showed the JS engine (a) returns IDENTICAL
  # output on SSR pages — pure waste — and (b) can REGRESS (GitHub: a page's JS wiped good SSR content,
  # 488 lines → 1). So: render fast first; only escalate to the ~11MB StarlingMonkey engine when the fast
  # result is THIN (a true client-only shell); and keep whichever output is richer — never regress.
  @thin_line_threshold 5
  defp render_html_auto(html, url, opts) do
    fast = render_html_boa(html, url, opts)

    if richness(fast) >= @thin_line_threshold do
      fast
    else
      js = render_html_jsdom(html, url, opts)
      if richness(js) > richness(fast), do: js, else: fast
    end
  end

  defp richness({:ok, t}) when is_binary(t),
    do: t |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))

  defp richness(_), do: 0

  defp render_html_boa(html, url, opts) do
    frozen = Nexus.Browse.Freeze.freeze(html, url, scripts: true)

    case run(:text_js, frozen, url, opts) do
      {:ok, text} when is_binary(text) and byte_size(text) > 0 -> {:ok, text}
      _ -> run(:text, html, url, opts)
    end
  end

  # The greenfield JS path: run the page's scripts against a REAL DOM (StarlingMonkey + linkedom),
  # then render the *hydrated* HTML with the no-JS renderer (the DOM is already built). Falls back to
  # the no-JS render of the original page if the JS engine isn't staged or errors.
  defp render_html_jsdom(html, url, opts) do
    with {:ok, hydrated} <- hydrate(html, url, opts) do
      run(:text, hydrated, url, opts)
    else
      _ -> run(:text, html, url, opts)
    end
  end

  @doc """
  Hydrate `html` by running its scripts against a real JS DOM (StarlingMonkey + linkedom) and return
  the serialized, hydrated HTML — the greenfield render. CSS stays inlined so a later screenshot is
  styled. `{:error, _}` if the JS engine/bundle isn't staged.
  """
  def hydrate(html, url, opts \\ []) do
    if Nexus.JsDom.available?() do
      frozen = Nexus.Browse.Freeze.freeze(html, url, scripts: true)
      scripts = Nexus.Browse.Freeze.script_bodies(frozen)
      Nexus.JsDom.render_html(frozen, scripts: scripts, settle_ms: Keyword.get(opts, :settle_ms, 50), timeout: Keyword.get(opts, :js_timeout, 60_000))
    else
      {:error, :jsdom_unavailable}
    end
  end

  @impl true
  def screenshot(url, opts) do
    with {:ok, html} <- fetch(url) do
      case Keyword.get(opts, :engine, :boa) do
        # Greenfield: hydrate via StarlingMonkey+linkedom (CSS stays inline), then paint the hydrated DOM.
        :jsdom ->
          case hydrate(html, url, opts) do
            {:ok, hydrated} -> run(:screenshot, hydrated, url, opts)
            _ -> run(:screenshot, Nexus.Browse.Freeze.freeze(html, url), url, opts)
          end

        # CSS inlined for layout; external scripts NOT inlined (a huge framework bundle aborts the JS
        # engine, and there's no text-fallback for a PNG). render_page still runs any light inline JS.
        _ ->
          frozen = Nexus.Browse.Freeze.freeze(html, url)
          run(:screenshot, frozen, url, opts)
      end
    end
  end

  defp fetch(url) do
    case Nexus.Dock.fetch(url) do
      "" -> {:error, :empty_or_blocked}
      html -> {:ok, html}
    end
  end

  # Write HTML into a throwaway VFS, run the appropriate render wasm in wasmtime, read the output.
  defp run(mode, html, base_url, opts) do
    dir = Path.join(System.tmp_dir!(), "nxbrowse_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "page.html"), html)

    {wasm, argv, out_file} =
      case mode do
        :text -> {priv("render_text.wasm"), ["/work/page.html", base_url], nil}
        :text_js -> {priv("render_js.wasm"), ["/work/page.html", base_url], nil}
        :screenshot ->
          w = Keyword.get(opts, :width, 1280)
          h = Keyword.get(opts, :height, 1600)
          {priv("render_page.wasm"), ["/work/page.html", "/work/out.png", base_url, "#{w}", "#{h}"], "out.png"}
      end

    # bound the JS engine: a huge framework bundle can spin/abort — kill it after the budget so the
    # caller falls back to the no-JS render. (wasmtime + a watchdog, like the agent bash kit timeout.)
    budget = Keyword.get(opts, :timeout_ms, 20_000)
    inner = ["wasmtime", "run", "--dir", "#{dir}::/work", wasm | argv] |> Enum.map_join(" ", &shq/1)
    secs = max(1, div(budget, 1000))
    guarded = "#{inner} & p=$!; { sleep #{secs}; kill -9 $p 2>/dev/null; } >/dev/null 2>&1 & w=$!; wait $p; rc=$?; kill $w 2>/dev/null; exit $rc"

    try do
      case System.cmd("sh", ["-c", guarded], stderr_to_stdout: false) do
        {stdout, 0} ->
          case out_file do
            nil -> {:ok, stdout}
            f -> File.read(Path.join(dir, f)) |> normalize()
          end

        {out, code} ->
          {:error, {:render_failed, code, String.slice(out, 0, 200)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp normalize({:ok, bin}), do: {:ok, bin}
  defp normalize(_), do: {:error, :no_output}

  defp priv(name), do: Application.get_env(:nexus, :"#{Path.basename(name, ".wasm")}", Path.join([File.cwd!(), "priv", name]))
end
