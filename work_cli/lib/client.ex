defmodule WorkCLI.Client do
  @moduledoc """
  The thin HTTP client `work` uses to talk to a **nexus** (or the cloud control plane) — the "client"
  half of the universal CLI. Just enough to health-check, query status, and post a command over
  HTTP(S). No engine, no NIF. Returns `{:ok, status, body} | {:error, reason}`.
  """

  @doc "GET `url` (default 10s). `{:ok, status, body} | {:error, reason}`."
  def get(url, opts \\ []) do
    request(:get, url, nil, opts)
  end

  @doc "POST `body` (a map, JSON-encoded) to `url`."
  def post(url, body, opts \\ []) do
    request(:post, url, Jason.encode!(body), opts)
  end

  defp request(method, url, body, opts) do
    :inets.start()
    :ssl.start()
    timeout = Keyword.get(opts, :timeout, 10_000)
    headers = Keyword.get(opts, :headers, []) |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      case method do
        :get -> {to_charlist(url), headers}
        :post -> {to_charlist(url), headers, ~c"application/json", body}
      end

    http_opts = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(method, req, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _}, _h, resp}} -> {:ok, status, resp}
      {:error, reason} -> {:error, reason}
    end
  end
end
