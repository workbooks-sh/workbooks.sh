defmodule Workbooks.PublicWeb do
  @moduledoc """
  The PUBLIC content plane (wb-1x1, PUBLIC-WEB-PLAN.org) — a SECOND, separate HTTP
  surface from `Workbooks.Web` (the authed control plane). This router is anonymous
  by design and serves ONE thing: the static, self-contained bytes of a published
  app, resolved by HOST.

  Hard isolation rules (the whole point of the plane split):
    * NO `Workbooks.Auth` plug — public, unauthenticated.
    * GET only — no writes, no Dock (`/w/:id/call`), no commands/build/agents, no
      secret access. None of those routes exist here, and this module never calls
      into them.
    * The page served carries NO call-home script to the control plane (unlike
      `Web.workbook_page/2`); it is static published content. Server-side compute
      for a public app is a later phase (the `:public` Policy profile).

  Resolution (P0): HOST's first DNS label IS the app id (e.g. `demo.apps.example`
  → workbook "demo"), read from the existing published store. P1 replaces this with
  the `Workbooks.Domains` registry (host → app, custom domains, TLS).
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    serve(conn)
  end

  # Any other path / method: this plane only serves the app at "/". No writes,
  # no Dock — anything else is a 404 (a non-GET never matches a `get` clause).
  match _ do
    send_resp(conn, 404, "not found")
  end

  defp serve(conn) do
    case app_id(conn) do
      nil ->
        send_resp(conn, 404, "no app for host")

      id ->
        case Workbooks.ControlPlane.get_workbook(id) do
          nil -> send_resp(conn, 404, "no app for host")
          org -> conn |> put_resp_content_type("text/html") |> send_resp(200, static_page(id, org))
        end
    end
  end

  # HOST → app id via the Domains registry (a registered host wins; otherwise it
  # falls back to the leftmost DNS label). conn.host is already port-stripped by Plug.
  defp app_id(conn), do: Workbooks.Domains.resolve(conn.host)

  @doc """
  A STATIC, self-contained page for the public plane: the rendered workbook with no
  backend call-home (contrast `Web.workbook_page/2`, which wires fetch/WS to the
  authed control plane). Public content is bytes only.
  """
  def static_page(id, org) do
    rendered = Workbooks.OQL.render(org)

    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{escape(id)}</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;color:#222}
    pre{background:#f6f7f9;padding:.6rem .8rem;border-radius:6px;overflow:auto}</style></head>
    <body><main id="app">#{rendered}</main></body></html>
    """
  end

  defp escape(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
