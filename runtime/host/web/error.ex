defmodule Workbooks.Web.Error do
  @moduledoc """
  The ONE error envelope every RCP client parses (RUNTIME-CONNECT-PROTOCOL.md §4):

      { "error": { "code": "...", "message": "...", "retryable": true|false } }

  Clients never parse raw HTTP bodies — they switch on `code`. `unavailable` is the
  "runtime down / unreachable" signal clients degrade on. Endpoints call
  `Workbooks.Web.Error.render/4` instead of hand-rolling `send_resp(4xx, "...")`.
  """
  import Plug.Conn

  # code → HTTP status. The vocabulary is closed (clients switch on it).
  @status %{
    bad_request: 400,
    unauthorized: 401,
    tenant_required: 401,
    forbidden: 403,
    not_found: 404,
    unavailable: 503,
    internal: 500
  }

  @doc "Send the uniform error envelope and halt the conn."
  def render(conn, code, message, opts \\ []) when is_atom(code) do
    status = Map.fetch!(@status, code)
    retryable = Keyword.get(opts, :retryable, code in [:unavailable, :internal])

    body =
      Jason.encode!(%{error: %{code: to_string(code), message: to_string(message), retryable: retryable}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
