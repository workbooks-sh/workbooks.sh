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

  # `tcp-send` — brokered one-shot raw TCP: send stdin bytes to HOST PORT, write the response to stdout. Covers
  # the DB-client / line-protocol class (Redis RESP, an HTTP/1 probe, a wire protocol) — the host opens the
  # socket (SSRF-pinned, {host,port}-scopable), the guest never does. Usage: tcp-send HOST PORT
  @tcp_send ~S"""
  import sys
  if len(sys.argv) < 3:
      sys.stderr.write("usage: tcp-send HOST PORT  (stdin bytes -> sent; response -> stdout)\n"); sys.exit(2)
  host = sys.argv[1]
  try:
      port = int(sys.argv[2])
  except ValueError:
      sys.stderr.write("port must be an integer\n"); sys.exit(2)
  data = sys.stdin.buffer.read()
  try:
      resp = wb_tcp(host, port, data)
      sys.stdout.buffer.write(resp); sys.exit(0)
  except OSError as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  # `pip-run` — the INSTALL half of pip for pure-Python packages, reclaimed: fetch the package's pure-Python
  # wheel over brokered HTTPS, download the wheel BYTES, and import it via zipimport (a wheel IS a zip → it goes
  # straight onto sys.path, no unpack). Then import the module (or run `-c CODE` against it). This is "pip
  # install + use" for the no-native-extension subset, entirely sandboxed + SSRF-mediated. Usage:
  #   pip-run PACKAGE [-c CODE]
  @pip_run ~S"""
  import sys, json, re
  args = sys.argv[1:]
  if not args:
      sys.stderr.write("usage: pip-run PACKAGE [-c CODE]\n"); sys.exit(2)
  pkg = args[0]
  code = args[2] if len(args) >= 3 and args[1] == "-c" else None
  import requests, urllib.error

  installed = {}
  def _norm(n): return n.lower().replace("_", "-")

  def _meta(name):
      r = requests.get("https://pypi.org/pypi/%s/json" % name)
      if r.status_code != 200:
          return None, None, []
      d = r.json(); ver = d["info"]["version"]; wheel = None
      for f in d.get("releases", {}).get(ver, []):
          if f.get("packagetype") == "bdist_wheel" and "none-any" in f.get("filename", ""):
              wheel = f["url"]; break
      return wheel, ver, d["info"].get("requires_dist") or []

  def _deps(requires_dist):
      out = []
      for r in requires_dist:
          if ";" in r:
              req, marker = r.split(";", 1)
              if "extra ==" in marker:   # optional-extra dep -> skip
                  continue
          else:
              req = r
          m = re.match(r"\s*([A-Za-z0-9_.\-]+)", req)
          if m: out.append(m.group(1))
      return out

  def _install(name):
      n = _norm(name)
      if n in installed: return
      wheel, ver, rd = _meta(name)
      if not wheel:
          sys.stderr.write("skip (no pure-python wheel): %s\n" % name); return
      path = "/b/%s.whl" % n.replace("-", "_")
      open(path, "wb").write(requests.get(wheel).content)
      sys.path.insert(0, path); installed[n] = ver
      for d in _deps(rd):
          _install(d)

  try:
      _install(pkg)
      if not installed:
          sys.stderr.write("not found / no pure-python wheel: %s\n" % pkg); sys.exit(3)
      # a freshly-installed real package must not be shadowed by a prelude shim of the same name -> drop ours.
      for n in list(installed):
          sys.modules.pop(n.replace("-", "_"), None)
      print("installed:", ", ".join("%s %s" % (k, v) for k, v in installed.items()))
      if code:
          exec(code)
      else:
          __import__(pkg.replace("-", "_"))
          print("import ok:", pkg)
      sys.exit(0)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  # The package-manager tools fetch from — and zipimport+execute code from — package registries. They are
  # SCOPED to those registry hosts (default-deny everything else), so a malicious package's import-time code
  # cannot turn the tool's net access into arbitrary-host EXFIL: an off-registry request is denied pre-DNS.
  @pypi_scope ["pypi.org", "files.pythonhosted.org", "*.pythonhosted.org"]
  @npm_scope ["registry.npmjs.org", "*.npmjs.org"]

  @doc "Register all canonical brokered tools. Returns `%{name => :ok | {:error, reason}}`. Idempotent."
  def register_all do
    %{
      "http" => register_http(),
      "pip-fetch" =>
        Workbooks.CommandRegistry.register_pynet("pip-fetch", @pip_fetch, :argv, %{allow: @pypi_scope}),
      "pip-run" =>
        Workbooks.CommandRegistry.register_pynet("pip-run", @pip_run, :argv, %{allow: @pypi_scope}),
      "npm-fetch" =>
        Workbooks.CommandRegistry.register_pynet("npm-fetch", @npm_fetch, :argv, %{allow: @npm_scope}),
      # raw TCP is a broader grant than http -> explicit :tcp_allow on this tool only.
      "tcp-send" =>
        Workbooks.CommandRegistry.register_pynet("tcp-send", @tcp_send, :argv, %{tcp_allow: true})
    }
  end

  @doc "Register the curl-class `http` client. `opts` may carry a per-instance `:allow` net scope (default: SSRF floor only)."
  def register_http(opts \\ %{}) do
    Workbooks.CommandRegistry.register_pynet("http", @http_client, :argv, opts)
  end

  @doc "The `http` client source (for inspection/tests)."
  def http_client_source, do: @http_client
end
