defmodule Workbooks.Publish.DesktopApp do
  @moduledoc """
  The `desktop-app` publish target (RCP-4 / wb-dl2): compile a workbook into a
  buildable desktop-app project whose frontend is the rendered workbook wired to a
  runtime via the Runtime Connect Protocol (RUNTIME-CONNECT-PROTOCOL.org).

  The author writes ZERO connection code. We emit:

      <out>/
        index.html        # the rendered workbook + an RCP bootstrap <script>
        rcp.js            # a portable RCP connector (plain ESM — same standard as
                          # desktop/src/lib/rcp; works in a raw browser, no build)
        tauri.conf.json   # generated from publish.org (name/version/identifier)
        README.txt        # the one command to produce the .app

  The connector targets `PUBLISH_URL` if set (a shared cloud runtime — the
  org-shared story), else the LOCAL discovery (when wrapped by a Tauri shell).
  `window.runtime` is the ready-to-use client. Producing the actual `.app` is the
  toolchain step (`tauri build`) the README documents — this target produces the
  buildable project deterministically.
  """

  @doc """
  Scaffold the desktop-app project beside the rendered HTML. Returns
  `{:ok, %{dir, files, url}}` or `{:error, reason}`.
  """
  def scaffold(html_path, p) do
    dir = Path.dirname(html_path)
    name = p["PUBLISH_APP_NAME"] || p["PUBLISH_TITLE"] || "Workbook"
    version = p["PUBLISH_VERSION"] || "0.1.0"
    identifier = p["PUBLISH_IDENTIFIER"] || "sh.workbooks.app.#{slug(name)}"
    # Runtime target: explicit URL (cloud) wins; else "" → local discovery at boot.
    url = p["PUBLISH_URL"] || ""
    posture = Workbooks.Publish.Config.access(p)

    # POSTURE-AWARE compilation (wb-9io): a gated workbook must NEVER inline its
    # content — even a "desktop" artifact can be copied to a web host. Public →
    # inline the rendered page; gated → emit a SHELL that fetches the content from
    # the runtime AFTER auth (the protected payload never touches the static file).
    {mode, html} =
      if Workbooks.Access.static_safe?(posture) do
        {:inline, File.read!(html_path) |> inject_bootstrap(url)}
      else
        content_path = p["PUBLISH_CONTENT_PATH"] || "/api/w/#{slug(name)}/html"
        {:shell, gated_shell(name, url, content_path)}
      end

    files = [
      {"index.html", html},
      {"rcp.js", rcp_js()},
      {"tauri.conf.json", tauri_conf(name, version, identifier)},
      {"README.txt", readme(name)}
    ]

    Enum.each(files, fn {rel, body} -> File.write!(Path.join(dir, rel), body) end)
    {:ok, %{dir: dir, files: Enum.map(files, &elem(&1, 0)), url: url, posture: posture, mode: mode}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Inject the RCP bootstrap before </body> (or </html>): import the connector and
  # expose window.runtime. baseUrl "" means "resolve locally" (the Tauri wrapper
  # injects the discovered url onto window.__RCP_BASE__).
  defp inject_bootstrap(html, url) do
    script = """
    <script type="module">
      import { createClient } from "./rcp.js";
      const baseUrl = #{js_string(url)} || (globalThis.__RCP_BASE__ ?? "");
      const getToken = async () => globalThis.__RCP_TOKEN__ ?? null;
      window.runtime = createClient({ baseUrl, getToken });
    </script>
    """

    cond do
      String.contains?(html, "</body>") -> String.replace(html, "</body>", script <> "</body>", global: false)
      String.contains?(html, "</html>") -> String.replace(html, "</html>", script <> "</html>", global: false)
      true -> html <> script
    end
  end

  # The GATED shell — a public page with NO inlined workbook content. It auths via
  # the RCP connector, then fetches the protected content from the runtime and
  # injects it. If the runtime refuses (unauthorized), it shows a sign-in prompt.
  # The protected payload never lives in this file (wb-9io anti-leak).
  defp gated_shell(name, url, content_path) do
    """
    <!doctype html>
    <html>
      <head><meta charset="utf-8" /><title>#{html_escape(name)}</title></head>
      <body>
        <main id="app" data-state="loading"><p>Loading…</p></main>
        <div id="auth" hidden><p>This workbook is protected. Please sign in.</p></div>
        <script type="module">
          import { createClient } from "./rcp.js";
          const baseUrl = #{js_string(url)} || (globalThis.__RCP_BASE__ ?? "");
          const getToken = async () => globalThis.__RCP_TOKEN__ ?? null;
          const rt = createClient({ baseUrl, getToken });
          window.runtime = rt;
          const app = document.getElementById("app");
          const auth = document.getElementById("auth");
          try {
            // Protected content is fetched at runtime, gated by the runtime.
            const res = await rt.request(#{js_string(content_path)});
            app.innerHTML = (res && res.html) ? res.html : (typeof res === "string" ? res : "");
            app.dataset.state = "ready";
          } catch (e) {
            const denied = e && (e.code === "unauthorized" || e.code === "tenant_required" || e.code === "forbidden");
            app.hidden = true;
            auth.hidden = false;
            auth.dataset.reason = denied ? "auth" : (e && e.code) || "error";
          }
        </script>
      </body>
    </html>
    """
  end

  defp html_escape(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp js_string(s), do: Jason.encode!(s)
  defp slug(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp tauri_conf(name, version, identifier) do
    Jason.encode!(
      %{
        "$schema" => "https://schema.tauri.app/config/2",
        "productName" => name,
        "version" => version,
        "identifier" => identifier,
        "build" => %{"frontendDist" => "."},
        "app" => %{"windows" => [%{"title" => name, "width" => 1100, "height" => 800}]},
        "bundle" => %{"active" => true, "targets" => "all"}
      },
      pretty: true
    )
  end

  defp readme(name) do
    """
    #{name} — a runtime-connected workbook desktop app (generated by `work publish`).

    The frontend (index.html + rcp.js) is ready. To produce the .app/.dmg:

      1. Scaffold a Tauri shell whose frontendDist points at this directory, OR
         drop these files into desktop/build/ of the workbooks desktop project.
      2. tauri build

    The connector is live at `window.runtime` — e.g. in the console:

      await window.runtime.capabilities()
      await window.runtime.request("/api/workbooks")

    It speaks the Runtime Connect Protocol; point PUBLISH_URL at any runtime
    (local sidecar or a shared cloud runtime) — no client changes.
    """
  end

  # The portable RCP connector, emitted verbatim. Plain ESM (no build step) so it
  # runs in a raw browser — the same contract as desktop/src/lib/rcp/client.ts.
  defp rcp_js do
    """
    // rcp.js — portable Runtime Connect Protocol client (generated).
    // Same standard as desktop/src/lib/rcp; spec: RUNTIME-CONNECT-PROTOCOL.org.
    export class RcpError extends Error {
      constructor(code, message, opts = {}) {
        super(message);
        this.name = "RcpError";
        this.code = code;
        this.retryable = opts.retryable ?? (code === "unavailable" || code === "internal");
        this.status = opts.status ?? 0;
      }
      get isUnavailable() { return this.code === "unavailable"; }
    }

    const WELL_KNOWN = "/.well-known/workbooks-runtime";

    export function createClient({ baseUrl, getToken = async () => null }) {
      let caps = null;
      const base = () => {
        if (!baseUrl) throw new RcpError("unavailable", "no runtime base url", { retryable: true });
        return baseUrl;
      };
      const _fetch = async (url, init) => {
        try { return await fetch(url, init); }
        catch (e) { throw new RcpError("unavailable", e?.message || "network error", { retryable: true }); }
      };
      const _err = (d, s) => {
        const e = d && d.error;
        if (e && e.code) return new RcpError(e.code, e.message || e.code, { retryable: e.retryable, status: s });
        return new RcpError("http_" + s, "HTTP " + s, { status: s });
      };
      return {
        async capabilities(force = false) {
          if (caps && !force) return caps;
          const r = await _fetch(base() + WELL_KNOWN, { headers: { accept: "application/json" } });
          const d = await r.json().catch(() => null);
          if (!r.ok || !d) throw new RcpError("unavailable", "no handshake", { status: r.status });
          return (caps = d);
        },
        async request(path, opts = {}) {
          const token = await getToken();
          const hasBody = opts.body !== undefined || opts.bodyText !== undefined;
          const r = await _fetch(base() + path + (opts.query ?? ""), {
            method: opts.method ?? (hasBody ? "POST" : "GET"),
            headers: {
              accept: "application/json",
              ...(hasBody ? { "content-type": opts.contentType ?? "application/json" } : {}),
              ...(token ? { authorization: "Bearer " + token } : {}),
            },
            body: opts.bodyText ?? (opts.body !== undefined ? JSON.stringify(opts.body) : undefined),
          });
          const d = await r.json().catch(() => null);
          if (!r.ok) throw _err(d, r.status);
          return d;
        },
        socket(path) {
          const ws = new WebSocket(base().replace(/^http/, "ws") + path);
          ws.addEventListener("open", async () => {
            const t = await getToken();
            if (t) ws.send(JSON.stringify({ auth: t }));
          });
          return ws;
        },
      };
    }
    """
  end
end
