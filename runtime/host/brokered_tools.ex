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

  # `pip-fetch` — the network half of pip, reclaimed: retrieve a package's metadata + distribution URLs from the
  # PyPI JSON API over the brokered transport (HTTPS through the full mediated stack). pip's blocker was
  # "network egress to PyPI"; this delivers exactly that, SSRF-safe. Usage: pip-fetch PACKAGE
  @pip_fetch ~S"""
  import sys, json
  if len(sys.argv) < 2:
      sys.stderr.write("usage: pip-fetch PACKAGE\n"); sys.exit(2)
  pkg = sys.argv[1]
  import requests, urllib.error
  try:
      r = requests.get("https://pypi.org/pypi/%s/json" % pkg)
      if r.status_code != 200:
          sys.stderr.write("not found: %s (%d)\n" % (pkg, r.status_code)); sys.exit(1)
      data = r.json()
      info = data.get("info", {})
      print("name:", info.get("name"))
      print("version:", info.get("version"))
      for f in data.get("releases", {}).get(info.get("version"), []):
          print("file:", f.get("packagetype"), f.get("url"))
      sys.exit(0)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  # `npm-fetch` — the network half of npm/pnpm/yarn: package metadata + tarball URL from the npm registry over
  # the brokered HTTPS stack. Usage: npm-fetch PACKAGE
  @npm_fetch ~S"""
  import sys, json
  if len(sys.argv) < 2:
      sys.stderr.write("usage: npm-fetch PACKAGE\n"); sys.exit(2)
  pkg = sys.argv[1]
  import requests, urllib.error
  try:
      r = requests.get("https://registry.npmjs.org/%s" % pkg)
      if r.status_code != 200:
          sys.stderr.write("not found: %s (%d)\n" % (pkg, r.status_code)); sys.exit(1)
      data = r.json()
      latest = data.get("dist-tags", {}).get("latest")
      print("name:", data.get("name"))
      print("version:", latest)
      dist = data.get("versions", {}).get(latest, {}).get("dist", {})
      print("tarball:", dist.get("tarball"))
      sys.exit(0)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  @doc "Register all canonical brokered tools. Returns `%{name => :ok | {:error, reason}}`. Idempotent."
  def register_all do
    %{
      "http" => register_http(),
      "pip-fetch" => Workbooks.CommandRegistry.register_pynet("pip-fetch", @pip_fetch, :argv, %{}),
      "npm-fetch" => Workbooks.CommandRegistry.register_pynet("npm-fetch", @npm_fetch, :argv, %{})
    }
  end

  @doc "Register the curl-class `http` client. `opts` may carry a per-instance `:allow` net scope (default: SSRF floor only)."
  def register_http(opts \\ %{}) do
    Workbooks.CommandRegistry.register_pynet("http", @http_client, :argv, opts)
  end

  @doc "The `http` client source (for inspection/tests)."
  def http_client_source, do: @http_client
end
