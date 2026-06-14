defmodule Workbooks.FlyMachines do
  @moduledoc """
  A thin client for the Fly Machines API (https://api.machines.dev/v1) — the host
  side that provisions a tenant's nexus (a Fly app + machine + volume) the same way
  `cli/deploy-kit/providers/fly/bootstrap.sh` does today, but in-process over the
  REST API instead of shelling `flyctl`.

  AUTH: a `Bearer` token from `FLY_API_TOKEN`. The token is a HOST credential and is
  the isolation key for the whole Fly org — so it is treated like the S3 secret:
  it NEVER appears in a log line, an error tuple, or any returned value. The only
  place it lives is the `authorization` request header handed straight to `:httpc`.

  SSRF FLOOR: the API host is the FIXED module constant `@api_host`
  (`https://api.machines.dev/v1`). It is never taken from caller/tenant input, so
  there is no way to point this client at an attacker-chosen origin. App and machine
  ids are validated as single opaque path segments (`safe_segment/1`) before they
  are interpolated into a URL — a `../`, slash, or query char fails closed.

  ERRORS: a non-2xx response maps to `{:error, {status, body}}` (the body is the
  Fly API's JSON, never our headers) — this never raises on an HTTP error. The
  HTTP layer is INJECTABLE: every public fn threads an `opts` keyword that can carry
  `:http` (a `fun(method, url, headers, body) -> {:ok, {status, body}} | {:error, term}`)
  so the request CONSTRUCTION (`build_request/4`, a pure fn) is unit-testable with no
  network at all.
  """

  @api_host "https://api.machines.dev/v1"

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Create a Fly app under `org` (org slug). POST /apps."
  def create_app(name, org, opts \\ []) do
    body = %{"app_name" => name, "org_slug" => org}
    request(:post, ["apps"], body, opts)
  end

  @doc "Create a machine in `app` from a Fly machine `config` map. POST /apps/:app/machines."
  def create_machine(app, config, opts \\ []) when is_map(config) do
    with {:ok, app} <- safe_segment(app) do
      request(:post, ["apps", app, "machines"], %{"config" => config}, opts)
    end
  end

  @doc "Start a stopped machine. POST /apps/:app/machines/:id/start."
  def start_machine(app, id, opts \\ []), do: machine_action(app, id, "start", opts)

  @doc "Stop a running machine. POST /apps/:app/machines/:id/stop."
  def stop_machine(app, id, opts \\ []), do: machine_action(app, id, "stop", opts)

  @doc "Destroy a machine (force). DELETE /apps/:app/machines/:id?force=true."
  def destroy_machine(app, id, opts \\ []) do
    with {:ok, app} <- safe_segment(app),
         {:ok, id} <- safe_segment(id) do
      request(:delete, ["apps", app, "machines", id <> "?force=true"], nil, opts)
    end
  end

  @doc "Fetch one machine. GET /apps/:app/machines/:id."
  def get_machine(app, id, opts \\ []) do
    with {:ok, app} <- safe_segment(app),
         {:ok, id} <- safe_segment(id) do
      request(:get, ["apps", app, "machines", id], nil, opts)
    end
  end

  @doc "List a machines in an app. GET /apps/:app/machines."
  def list_machines(app, opts \\ []) do
    with {:ok, app} <- safe_segment(app) do
      request(:get, ["apps", app, "machines"], nil, opts)
    end
  end

  defp machine_action(app, id, action, opts) do
    with {:ok, app} <- safe_segment(app),
         {:ok, id} <- safe_segment(id) do
      request(:post, ["apps", app, "machines", id, action], nil, opts)
    end
  end

  # ── Pure request construction (network-free; unit-testable) ─────────────────────

  @doc """
  Build the `{method, url, headers, body}` 4-tuple for a call WITHOUT performing it.
  Pure and network-free. `segments` is a list of already-validated path segments
  appended to the fixed `@api_host`. `body` is a map (JSON-encoded) or nil.

  The `Authorization: Bearer <token>` header is DELIBERATELY NOT added here — the
  token is injected only in the private HTTP layer (`do_request/4`) right before
  the `:httpc` call, so it never appears in this pure return value, a log, or a
  test fixture.
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
  # The pinned TLS http-options for the Fly API. SNI is hard-pinned to the fixed
  # api.machines.dev host (same verify_peer pattern as `Workbooks.NetGuard`).
  # Exposed so the test can regression-lock verify_peer + non-empty cacerts + SNI.
  def http_options do
    [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"api.machines.dev",
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  # ── Internal: construct + dispatch + map ────────────────────────────────────────

  # Cap the response body read so a hostile/oversized response can't exhaust memory.
  # Fly API responses are small JSON; a few MB is generous headroom.
  @max_body_bytes 8 * 1024 * 1024

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || System.get_env("FLY_API_TOKEN") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc (mirrors Storage.S3's do_http style). The `Authorization:
  # Bearer <token>` header is added HERE — never by `build_request` — so the token
  # lives only in the request handed straight to `:httpc`. TLS is verified
  # (verify_peer + pinned SNI) so the token can't be MITM-stolen. Never logs headers.
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

  # An app/machine id must be a single opaque path segment: a non-empty binary with
  # no slash, no dot-segment, no query/fragment chars. Fails closed otherwise so a
  # crafted "../other-app" can never escape into a sibling resource.
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
