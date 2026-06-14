defmodule Workbooks.Neon do
  @moduledoc """
  A thin client for the Neon API (https://console.neon.tech/api/v2) — the host
  side that provisions a per-tenant Postgres (a Neon project + its pooled
  connection string) in-process over the REST API.

  Mirrors `Workbooks.FlyMachines` exactly:

  AUTH: a `Bearer` token from `NEON_API_KEY`. The key is a HOST credential and the
  isolation key for the whole Neon org — so it NEVER appears in a log line, an
  error tuple, or any returned value. It lives only in the `authorization` request
  header handed straight to `:httpc` (added in `do_request/4`, never in
  `build_request/4`).

  SSRF FLOOR: the API host is the FIXED module constant `@api_host`
  (`https://console.neon.tech/api/v2`). It is never taken from caller/tenant
  input, so this client can't be pointed at an attacker-chosen origin. Project
  ids are validated as single opaque path segments (`safe_segment/1`) before
  interpolation — a `../`, slash, or query char fails closed.

  ERRORS: a non-2xx response maps to `{:error, {status, body}}` (the body is
  Neon's JSON, never our headers) — never raises on an HTTP error. The HTTP layer
  is INJECTABLE: every public fn threads an `opts` keyword carrying `:http`
  (`fun(method, url, headers, body) -> {:ok, {status, body}} | {:error, term}`)
  so the request CONSTRUCTION (`build_request/4`, pure) is unit-testable with no
  network at all.

  ENDPOINTS — confirmed against the Neon API reference / OpenAPI spec
  (https://neon.com/api_spec/release/v2.json, https://api-docs.neon.tech):
    * create project        — POST   /projects
                              (api-docs.neon.tech/reference/createproject)
    * get connection URI    — GET    /projects/:id/connection_uri
                              (api-docs.neon.tech/reference/getconnectionuri)
                              required query: database_name, role_name; optional: pooled
    * delete project        — DELETE /projects/:id
                              (api-docs.neon.tech/reference/deleteproject)
  """

  @api_host "https://console.neon.tech/api/v2"
  @sni ~c"console.neon.tech"

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Create a Neon project named `name`. POST /projects.

  Request body is the Neon `{"project": {...}}` wrapper. `opts[:project]` may
  carry extra project fields (e.g. `pg_version`, `region_id`) merged under the
  wrapper. On success returns the decoded body, which contains the created
  `project.id` and a `connection_uris` array (each with a `connection_uri` DSN).
  """
  def create_project(name, opts \\ []) when is_binary(name) do
    project = Map.merge(Keyword.get(opts, :project, %{}), %{"name" => name})
    request(:post, ["projects"], %{"project" => project}, opts)
  end

  @doc """
  Get a project's pooled connection URI. GET /projects/:id/connection_uri.

  `database_name` and `role_name` are required by the Neon API. Defaults to the
  `pooled` connection string (`opts[:pooled]`, default `true`); pass
  `pooled: false` for the direct connection. `opts[:database_name]` /
  `opts[:role_name]` override the defaults (`"neondb"` / `"neondb_owner"`).
  """
  def get_connection_uri(project_id, opts \\ []) do
    with {:ok, id} <- safe_segment(project_id) do
      query =
        URI.encode_query(%{
          "database_name" => Keyword.get(opts, :database_name, "neondb"),
          "role_name" => Keyword.get(opts, :role_name, "neondb_owner"),
          "pooled" => to_string(Keyword.get(opts, :pooled, true))
        })

      request(:get, ["projects", id <> "/connection_uri?" <> query], nil, opts)
    end
  end

  @doc "Delete a Neon project (and everything in it). DELETE /projects/:id."
  def delete_project(project_id, opts \\ []) do
    with {:ok, id} <- safe_segment(project_id) do
      request(:delete, ["projects", id], nil, opts)
    end
  end

  # ── Pure request construction (network-free; unit-testable) ─────────────────────

  @doc """
  Build the `{method, url, headers, body}` 4-tuple for a call WITHOUT performing
  it. Pure and network-free. `segments` is a list of already-validated path
  segments appended to the fixed `@api_host`. `body` is a map (JSON-encoded) or nil.

  The `Authorization: Bearer <key>` header is DELIBERATELY NOT added here — the
  key is injected only in the private HTTP layer (`do_request/4`) right before the
  `:httpc` call, so it never appears in this pure return value, a log, or a test
  fixture.
  """
  def build_request(method, segments, body, _opts \\ []) when is_list(segments) do
    url = @api_host <> "/" <> Enum.join(segments, "/")

    headers =
      [{"accept", "application/json"}] ++
        if(is_map(body), do: [{"content-type", "application/json"}], else: [])

    encoded = if is_map(body), do: json_encode(body), else: ""
    {method, url, headers, encoded}
  end

  @doc false
  # The fixed API host — exposed for the test that asserts no caller can change it.
  def api_host, do: @api_host

  @doc false
  # The pinned TLS http-options for the Neon API. SNI is hard-pinned to the fixed
  # console.neon.tech host (same verify_peer pattern as `Workbooks.FlyMachines`).
  # Exposed so the test can regression-lock verify_peer + non-empty cacerts + SNI.
  def http_options do
    [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: @sni,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  # ── Internal: construct + dispatch + map ────────────────────────────────────────

  # Cap the response body read so a hostile/oversized response can't exhaust memory.
  @max_body_bytes 8 * 1024 * 1024

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || System.get_env("NEON_API_KEY") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc. The `Authorization: Bearer <key>` header is added HERE —
  # never by `build_request` — so the key lives only in the request handed straight
  # to `:httpc`. TLS is verified (verify_peer + pinned SNI) so the key can't be
  # MITM-stolen. Never logs headers.
  defp do_request(method, url, headers, body, token) do
    :inets.start()
    :ssl.start()

    headers = [{"authorization", "Bearer " <> token} | headers]
    http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch, :delete] and body != "" do
        {to_charlist(url), http_headers, ~c"application/json", body}
      else
        {to_charlist(url), http_headers}
      end

    case :httpc.request(method, req, http_options(), body_format: :binary) do
      {:ok, {{_, code, _}, _resp_headers, resp}} -> {:ok, {code, cap_body(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp cap_body(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes,
    do: binary_part(bin, 0, @max_body_bytes)

  defp cap_body(bin), do: bin

  # ── Guards & codecs ─────────────────────────────────────────────────────────────

  # A project id must be a single opaque path segment: a non-empty binary with no
  # slash, no dot-segment, no query/fragment chars. Fails closed otherwise so a
  # crafted "../other-project" can never escape into a sibling resource.
  defp safe_segment(s) when is_binary(s) and s != "" do
    cond do
      String.contains?(s, ["/", "\\", "?", "#", "%", " "]) -> {:error, :invalid_id}
      s in [".", ".."] -> {:error, :invalid_id}
      # Reject any C0 control char (incl. NUL, CR, LF, TAB) and DEL.
      String.match?(s, ~r/[\x00-\x1f\x7f]/) -> {:error, :invalid_id}
      true -> {:ok, s}
    end
  end

  defp safe_segment(_), do: {:error, :invalid_id}

  defp json_encode(map), do: Jason.encode!(map)

  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      {:error, _} -> bin
    end
  end
end
