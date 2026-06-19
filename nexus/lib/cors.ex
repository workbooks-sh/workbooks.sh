defmodule Nexus.Cors do
  @moduledoc """
  CORS for the RCP surface. The desktop webview (Tauri) and any browser client fetch nexus
  CROSS-ORIGIN (a remote nexus URL ≠ the app's origin), so the browser enforces CORS: a preflight
  `OPTIONS` must be answered, and every response needs `Access-Control-Allow-Origin`. Without this the
  desktop→cloud-nexus fetch (the transport cutover's cloud path) is blocked.

  `Allow-Origin: *` is safe here because auth is a **Bearer token** in the `Authorization` header, never
  a cookie — there are no ambient credentials for another origin to ride, so `*` exposes nothing the
  token doesn't already gate. The preflight is answered BEFORE auth (the browser sends `OPTIONS` with no
  token); it carries no tenant data.
  """
  import Plug.Conn

  @methods "GET, POST, PATCH, DELETE, OPTIONS"
  @headers "authorization, content-type, accept"

  def init(opts), do: opts

  # Preflight — answer 204 with the CORS headers, BEFORE the auth plug (no token on a preflight).
  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn |> cors() |> send_resp(204, "") |> halt()
  end

  # Real request — attach the CORS headers to whatever response the routes produce.
  def call(conn, _opts), do: register_before_send(conn, &cors/1)

  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", @methods)
    |> put_resp_header("access-control-allow-headers", @headers)
    |> put_resp_header("access-control-max-age", "86400")
  end
end
