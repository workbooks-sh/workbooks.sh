defmodule Workbooks.CappedHttp do
  @moduledoc """
  wb-j3n8: a streaming HTTP GET with a HARD response-body byte cap and an absolute wall-clock deadline — the
  outbound DoS floor (mirrors the inbound `Limited` serve-body cap, iter74). The sync `:httpc.request` reads
  the ENTIRE upstream body into host memory before anyone can truncate it, so a guest fetching a huge response
  causes a host memory DoS. Here we stream the response (`{:stream, :self}`) and accumulate body parts only up
  to `max_bytes`, cancelling the request the instant it overflows — the host never buffers more than the cap.

  `:httpc` async streaming delivers `{:http, {id, :stream_start, Headers}}` (headers, NO status line) then
  `{:http, {id, :stream, Part}}*` then `{:http, {id, :stream_end, _}}`. We return the response Headers (the
  caller detects a redirect via the `location` header, since the status isn't available) and the capped body.

  Returns `{:ok, headers, body}` | `{:error, :too_large | :timeout | :request_failed}`.
  """

  @doc """
  Streaming GET capped at `max_bytes` body and `timeout` ms TOTAL (absolute deadline — a slowloris drip can't
  reset it). `headers` is an :httpc header list (charlists); `http_opts` is the :httpc http_options list.
  """
  def get(url, headers, http_opts, max_bytes, timeout)
      when is_integer(max_bytes) and max_bytes >= 0 and is_integer(timeout) do
    opts = [{:sync, false}, {:stream, :self}, {:body_format, :binary}]
    deadline = System.monotonic_time(:millisecond) + timeout

    case :httpc.request(:get, {url, headers}, http_opts, opts) do
      {:ok, req_id} -> collect(req_id, max_bytes, [], 0, [], deadline)
      _ -> {:error, :request_failed}
    end
  end

  defp collect(req_id, max, acc, n, resp_headers, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:http, {^req_id, :stream_start, headers}} ->
        collect(req_id, max, acc, n, headers, deadline)

      {:http, {^req_id, :stream_start, headers, _pid}} ->
        collect(req_id, max, acc, n, headers, deadline)

      {:http, {^req_id, :stream, part}} ->
        n2 = n + byte_size(part)

        if n2 > max do
          # the host stops reading the instant the cap is exceeded — never buffers the whole oversized body
          :httpc.cancel_request(req_id)
          {:error, :too_large}
        else
          collect(req_id, max, [part | acc], n2, resp_headers, deadline)
        end

      {:http, {^req_id, :stream_end, _trailers}} ->
        {:ok, resp_headers, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      # small bodies may arrive as a single non-streamed result tuple (with the status line)
      {:http, {^req_id, {{_v, _status, _r}, headers, body}}} when is_binary(body) ->
        if byte_size(body) > max, do: {:error, :too_large}, else: {:ok, headers, body}

      {:http, {^req_id, {:error, _reason}}} ->
        {:error, :request_failed}
    after
      remaining ->
        :httpc.cancel_request(req_id)
        {:error, :timeout}
    end
  end
end
