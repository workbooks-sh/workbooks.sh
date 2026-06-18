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

  # Rendered text — CSS-aware via Blitz, no JS. Text lives in the HTML, so no freeze needed (faster).
  @impl true
  def render(url, opts) do
    with {:ok, html} <- fetch(url) do
      run(:text, html, url, opts)
    end
  end

  @impl true
  def screenshot(url, opts) do
    with {:ok, html} <- fetch(url) do
      frozen = Nexus.Browse.Freeze.freeze(html, url)
      run(:screenshot, frozen, url, opts)
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
        :text ->
          {wasm(:text), ["/work/page.html", base_url], nil}

        :screenshot ->
          w = Keyword.get(opts, :width, 1280)
          h = Keyword.get(opts, :height, 1600)
          {wasm(:screenshot), ["/work/page.html", "/work/out.png", base_url, "#{w}", "#{h}"], "out.png"}
      end

    args = ["run", "--dir", "#{dir}::/work", wasm | argv]

    try do
      case System.cmd("wasmtime", args, stderr_to_stdout: false) do
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

  defp normalize({:ok, bin}), do: {:ok, bin}
  defp normalize(_), do: {:error, :no_output}

  defp wasm(:text), do: Application.get_env(:nexus, :render_text_wasm, priv("render_text.wasm"))
  defp wasm(:screenshot), do: Application.get_env(:nexus, :render_page_wasm, priv("render_page.wasm"))
  defp priv(name), do: Path.join([File.cwd!(), "priv", name])
end
