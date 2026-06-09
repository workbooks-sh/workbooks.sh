defmodule Workbooks.CLI.Runtime do
  @moduledoc """
  `wb rt …` — drive a RUNNING runtime over HTTP as a first-class RCP client
  (wb-82g; RUNTIME-CONNECT-PROTOCOL.org). The CLI is just another client: it
  resolves a target + credential, then speaks the same HTTP contract the desktop
  and web clients do.

      wb rt status                 # the /.well-known capabilities handshake + health
      wb rt get  <path>            # GET  <path>
      wb rt post <path> [<json>]   # POST <path> with an optional JSON body

  Target resolution (first wins):
    * WB_RUNTIME_URL + WB_TOKEN          — explicit (a remote/cloud runtime, or CI)
    * the local discovery file runtime.json — the trusted rung (a local daemon)

  HTTP is built-in `:httpc` (no new dep), same as Workbooks.Auth.JWKS.
  """
  @well_known "/.well-known/workbooks-runtime"

  @doc "Entry point for `wb rt …`. Returns {output, failed?}. `req` is injectable for tests."
  def run(args, req \\ &http_request/4)

  def run(["status"], req), do: status(req)
  def run(["get", path], req), do: do_request(:get, path, nil, req)
  def run(["post", path], req), do: do_request(:post, path, "", req)
  def run(["post", path, body], req), do: do_request(:post, path, body, req)
  def run(_, _), do: {usage(), true}

  @doc """
  `wb ctk await <run> [timeout_s]` — block until a CTK review (a human clicking
  Commit in the CTK shell, which POSTs /api/ctk/commit?run=<run>) lands, then
  print it. Same target + transport as `wb rt`. The agent's open→await→commit
  primitive (it has only bash; this wraps the poll loop).
  """
  def ctk(args, req \\ &http_request/4)
  def ctk(["await", run], req), do: await_review(run, 600, req)
  def ctk(["await", run, t], req), do: await_review(run, String.to_integer(t), req)
  def ctk(_, _), do: {ctk_usage(), true}

  defp await_review(run, timeout_s, req) do
    case target() do
      {:error, msg} -> {msg, true}
      {:ok, t} -> poll_review(t, run, req, System.monotonic_time(:second) + timeout_s)
    end
  end

  defp poll_review(t, run, req, deadline) do
    case req.(:get, t.url <> "/api/ctk/review/#{run}", nil, t.token) do
      {:ok, 200, decoded} when decoded not in [nil, "", %{}] ->
        {pretty(decoded), false}

      {:ok, code, _} when code in 200..299 ->
        if System.monotonic_time(:second) >= deadline do
          {"timed out waiting for a CTK review on #{run}", true}
        else
          Process.sleep(2000)
          poll_review(t, run, req, deadline)
        end

      {:ok, 404, _} ->
        {"no such run: #{run}", true}

      {:ok, code, decoded} ->
        {pretty(decoded) <> "\n(HTTP #{code})", true}

      {:error, msg} ->
        {"request failed: #{msg}", true}
    end
  end

  defp ctk_usage do
    """
    wb ctk await <run> [timeout_s]   block until a CTK review for <run> arrives, then print it

    The human clicks Commit in the CTK shell (POSTs /api/ctk/commit?run=<run>);
    this polls GET /api/ctk/review/<run> until it lands. Target: WB_RUNTIME_URL
    (+ WB_TOKEN), else the local discovery file.
    """
  end

  @doc """
  Resolve {url, token}. Env wins (remote/CI); else the local discovery file.
  Returns {:ok, %{url, token, source}} | {:error, reason}.
  """
  def target do
    case System.get_env("WB_RUNTIME_URL") do
      url when is_binary(url) and url != "" ->
        {:ok, %{url: String.trim_trailing(url, "/"), token: System.get_env("WB_TOKEN", ""), source: "env"}}

      _ ->
        from_discovery()
    end
  end

  defp from_discovery do
    path = Workbooks.Desktop.discovery_path()

    with {:ok, body} <- File.read(path),
         {:ok, %{"port" => port} = d} <- Jason.decode(body) do
      scheme = Map.get(d, "scheme", "http")
      {:ok, %{url: "#{scheme}://127.0.0.1:#{port}", token: Map.get(d, "token", ""), source: "discovery"}}
    else
      _ -> {:error, "no runtime: start one (`wb deploy local`) or set WB_RUNTIME_URL (+ WB_TOKEN)"}
    end
  end

  # The /.well-known handshake (public) + an authed /health probe.
  defp status(req) do
    case target() do
      {:error, msg} ->
        {msg, true}

      {:ok, t} ->
        case req.(:get, t.url <> @well_known, nil, t.token) do
          {:ok, _code, doc} ->
            {Jason.encode!(Map.put(doc, "_target", %{url: t.url, source: t.source}), pretty: true), false}

          {:error, msg} ->
            {"runtime unreachable at #{t.url}: #{msg}", true}
        end
    end
  end

  defp do_request(method, path, body, req) do
    case target() do
      {:error, msg} ->
        {msg, true}

      {:ok, t} ->
        path = if String.starts_with?(path, "/"), do: path, else: "/" <> path

        case req.(method, t.url <> path, body, t.token) do
          {:ok, code, decoded} when code in 200..299 ->
            {pretty(decoded), false}

          {:ok, code, decoded} ->
            # The runtime speaks the §4 error envelope; surface code + message.
            {pretty(decoded) <> "\n(HTTP #{code})", true}

          {:error, msg} ->
            {"request failed: #{msg}", true}
        end
    end
  end

  defp pretty(s) when is_binary(s), do: s
  defp pretty(term), do: Jason.encode!(term, pretty: true)

  # --- transport: :httpc with the Bearer credential (mirrors Auth.JWKS) --------
  defp http_request(method, url, body, token) do
    :inets.start()
    :ssl.start()
    headers = [{~c"accept", ~c"application/json"}] ++ auth_header(token)

    request =
      case method do
        :get -> {String.to_charlist(url), headers}
        :post -> {String.to_charlist(url), headers, ~c"application/json", body || ""}
      end

    case :httpc.request(method, request, [], body_format: :binary) do
      {:ok, {{_v, code, _r}, _h, resp}} -> {:ok, code, decode(resp)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp auth_header(""), do: []
  defp auth_header(nil), do: []
  defp auth_header(token), do: [{~c"authorization", String.to_charlist("Bearer " <> token)}]

  defp decode(""), do: %{}
  defp decode(resp) do
    case Jason.decode(resp) do
      {:ok, term} -> term
      _ -> resp
    end
  end

  defp usage do
    """
    wb rt — talk to a running runtime over HTTP (RCP client).

      wb rt status                 the capabilities handshake + target
      wb rt get  <path>            GET  <path>   (e.g. /api/workbooks)
      wb rt post <path> [<json>]   POST <path> with an optional JSON body

    Target: WB_RUNTIME_URL (+ WB_TOKEN), else the local discovery file.
    """
  end
end
