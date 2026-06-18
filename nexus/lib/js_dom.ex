defmodule Nexus.JsDom do
  @moduledoc """
  **The greenfield render path** — run a page's JavaScript against a *real DOM*, fully in wasmtime,
  no V8, no Chromium. We load **linkedom** (a server-grade pure-JS DOM) inside **StarlingMonkey**
  (`Nexus.JsEngine`), expose `document`/`window`/`location`/`navigator` as globals, then run the
  page's own scripts against it and serialize the hydrated DOM back to HTML.

  This is the engine that beats Boa: StarlingMonkey has no capacity wall and a real **event loop**
  (Promises/async settle), so framework JS runs. The DOM is JS (linkedom), so we dodge the
  539-hand-bound-interface wall. Per the research, we do NOT bridge live layout — geometry isn't
  needed here: computer-use acts by element number, and screenshots come from a one-way
  serialize → Blitz render. `render_html/2` gives the hydrated HTML; feed it to `Nexus.Browse.Blitz`
  for text/screenshot.

      Nexus.JsDom.render_html("<div id=app></div>", scripts: ["document.getElementById('app').innerHTML='<h1>hi</h1>'"])
      #=> {:ok, "<html>…<div id=\"app\"><h1>hi</h1></div>…"}
  """

  @doc """
  Run `scripts` against a real DOM seeded from `html`, return the hydrated, serialized HTML.

    * `:scripts` — list of JS source strings (the page's inlined `<script>` bodies), run in order
    * `:settle_ms` — let the event loop drain this long before serializing (default 0; bump for async)
    * `:timeout` — overall wasm wall-clock (default 30s)
  """
  def render_html(html, opts \\ []) when is_binary(html) do
    scripts = Keyword.get(opts, :scripts, [])
    settle = Keyword.get(opts, :settle_ms, 0)
    timeout = Keyword.get(opts, :timeout, 30_000)

    src = harness(html, scripts, settle)
    Nexus.JsEngine.eval(src, timeout: timeout)
  end

  @doc "Whether the JS-DOM bundle is staged."
  def available?, do: File.exists?(bundle_path()) and Nexus.JsEngine.available?()

  # ── the eval harness: linkedom + global DOM + page scripts + async serialize ────────────────
  defp harness(html, scripts, settle) do
    page = Enum.map_join(scripts, "\n;\n", &wrap_script/1)

    """
    #{bundle()}
    ;
    const { window, document } = linkedom.parseHTML(#{json(html)});
    globalThis.window = window;
    globalThis.document = document;
    globalThis.navigator = window.navigator;
    globalThis.location = window.location;
    globalThis.self = window;
    globalThis.HTMLElement = window.HTMLElement;
    globalThis.Node = window.Node;
    globalThis.customElements = window.customElements;
    #{page}
    ;
    // Let microtasks/timers drain, then serialize the hydrated DOM (StarlingMonkey awaits this thenable).
    (async () => {
      await new Promise(r => setTimeout(r, #{settle}));
      return document.toString();
    })();
    """
  end

  # A page script must not abort the whole render if it throws — isolate each.
  defp wrap_script(js), do: "try { (function(){ #{js}\n })(); } catch (e) { /* page script error: */ }"

  defp bundle, do: File.read!(bundle_path())
  defp bundle_path, do: Application.get_env(:nexus, :jsdom_bundle, Path.join([File.cwd!(), "priv", "jsdom.js"]))

  # Encode an Elixir string as a JS string literal.
  defp json(s), do: Jason.encode!(s)
end
