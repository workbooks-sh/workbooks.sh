defmodule Workbooks.BrokeredTools do
  @moduledoc """
  Canonical host-brokered CLI tools — the Phase-4 reclaim "keystones": real, shipped commands that deliver a
  network/orchestration CAPABILITY through the mediated brokers, so the sandbox gains the curl/httpie/wget class
  of tool without a per-binary port. Each is a `:pynet` command: it runs CPython with the brokered transport, so
  every request goes through NetGuard (SSRF/allow-list/pin/rate/revocation) and every exec through ExecBroker.

  Registered at boot (Workbooks.Application) so they're first-class commands alongside jq/grep/python.
  """

  # `http` — a curl/httpie-class HTTP client over the brokered transport. Usage:
  #   http [METHOD] URL [-H "K: V"]... [-d DATA]
  # prints the response body to stdout; exit 0 on 2xx/3xx, 1 on >=4xx or a denied/failed request.
  @http_client ~S"""
  import sys
  args = sys.argv[1:]
  method = "GET"
  if args and args[0].upper() in ("GET", "POST", "PUT", "DELETE", "HEAD", "PATCH"):
      method = args[0].upper(); args = args[1:]
  url = None; headers = {}; data = None
  i = 0
  while i < len(args):
      a = args[i]
      if a == "-H" and i + 1 < len(args):
          k, _, v = args[i + 1].partition(":"); headers[k.strip()] = v.strip(); i += 2
      elif a == "-d" and i + 1 < len(args):
          data = args[i + 1]
          if method == "GET": method = "POST"
          i += 2
      elif url is None:
          url = a; i += 1
      else:
          i += 1
  if not url:
      sys.stderr.write("usage: http [METHOD] URL [-H 'K: V']... [-d DATA]\n"); sys.exit(2)
  import requests, urllib.error
  try:
      r = requests.request(method, url, headers=headers, data=data)
      sys.stdout.write(r.text)
      sys.exit(0 if r.status_code < 400 else 1)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  @doc "Register all canonical brokered tools. Returns `%{name => :ok | {:error, reason}}`. Idempotent."
  def register_all do
    %{"http" => register_http()}
  end

  @doc "Register the curl-class `http` client. `opts` may carry a per-instance `:allow` net scope (default: SSRF floor only)."
  def register_http(opts \\ %{}) do
    Workbooks.CommandRegistry.register_pynet("http", @http_client, :argv, opts)
  end

  @doc "The `http` client source (for inspection/tests)."
  def http_client_source, do: @http_client
end
