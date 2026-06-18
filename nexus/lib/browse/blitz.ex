defmodule Nexus.Browse.Blitz do
  @moduledoc """
  The in-wasm render provider — Blitz (Stylo CSS + Taffy layout + Vello-CPU paint) running in
  wasmtime via `render_page.wasm`. Capabilities `:render` (rendered text) + `:screenshot` (PNG). The
  page is fetched + frozen host-side (`Nexus.Browse.Freeze`), then rendered IN the sandbox — no
  Chromium, no native browser, no GPU. No JS yet (SPAs render their server shell; see the browse plan).
  """
  @behaviour Nexus.Browse

  @impl true
  def capabilities, do: [:screenshot]

  @impl true
  def screenshot(url, opts) do
    with {:ok, html} <- fetch(url),
         frozen <- Nexus.Browse.Freeze.freeze(html, url),
         {:ok, png} <- render_png(frozen, url, opts) do
      {:ok, png}
    end
  end

  @impl true
  def render(_url, _opts), do: {:error, :render_text_not_yet}

  defp fetch(url) do
    case Nexus.Dock.fetch(url) do
      "" -> {:error, :empty_or_blocked}
      html -> {:ok, html}
    end
  end

  # Write the frozen HTML into a throwaway VFS, run render_page.wasm in wasmtime, read the PNG.
  defp render_png(html, base_url, opts) do
    w = Keyword.get(opts, :width, 1280)
    h = Keyword.get(opts, :height, 1600)
    dir = Path.join(System.tmp_dir!(), "nxbrowse_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "page.html"), html)

    args = ["run", "--dir", "#{dir}::/work", wasm(), "/work/page.html", "/work/out.png", base_url, "#{w}", "#{h}"]

    try do
      case System.cmd("wasmtime", args, stderr_to_stdout: true) do
        {_, 0} ->
          case File.read(Path.join(dir, "out.png")) do
            {:ok, png} -> {:ok, png}
            _ -> {:error, :no_output}
          end

        {out, code} ->
          {:error, {:render_failed, code, String.slice(out, 0, 200)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp wasm, do: Application.get_env(:nexus, :render_page_wasm, Path.join([File.cwd!(), "priv", "render_page.wasm"]))
end
