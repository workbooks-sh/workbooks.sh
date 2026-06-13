defmodule Workbooks.Reclaim.PdmTest do
  @moduledoc """
  RECLAIM (durable) — `pdm`.

  resolved.json reclaim recipe (verbatim intent): pdm is pure-Python. Its full CLI is gated by single-threaded
  wasip1 (threads + getuid), but its RESOLVER-FACING surface — "requirement / specifier / metadata parsing" —
  is reproducible in-sandbox: stage pdm's pure-python wheels over the brokered HTTPS transport (zipimport, no
  native ext modules), "inject only an `mmap` ModuleType stub", and drive the real pdm parsing APIs.

  This test is SELF-CONTAINED: it registers its own pip-install-class `:pynet` tool inline (scoped to
  PyPI/pythonhosted), so it does not depend on Workbooks.BrokeredTools or any shared registration.

  What it proves empirically (each over the real brokered HTTPS stack, then zipimported in-sandbox):
    - pdm's resolver/parser CLOSURE (pdm + packaging + dep-logic + tomlkit + resolvelib + unearth + its http
      stack — all pure-python "none-any" wheels) is fetched + installed in-sandbox with zero native ext deps;
    - pdm's REAL parsing core runs: `pdm.models.requirements.parse_requirement` parses a PEP 508 requirement
      into a normalized key + specifier, and `pdm.models.specifiers.PySpecSet` evaluates a Python-version
      constraint correctly. That is the resolver-facing surface the campaign flipped reachable->live.

  HONEST SCOPE (matches resolved.json `pip_run_status`): this reproduces pdm's RESOLVER/METADATA-PARSING
  capability (its library core) — NOT the full `pdm install` CLI. The full CLI is gated by threads/getuid under
  wasip1, AND installing pdm's *entire* tree (virtualenv ~7.4MB + pygments + rich) over the broker blows the
  wasm execution deadline (exit 134) — "reachable-but-HEAVY", as the recipe itself records. So this test stages
  only the curated PARSING closure (lightweight, ~3s) and exercises the real APIs — durably true, not over-claimed.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  # pip-install-class tool, registered INLINE (not via BrokeredTools) so the test is self-contained. Fetches
  # an EXPLICIT, curated list of pure-python "none-any" wheels over brokered HTTPS, downloads the bytes, and
  # zipimports each (a wheel IS a zip → straight onto sys.path). `-c CODE` then runs against the staged tree.
  @installer ~S"""
  import sys
  args = sys.argv[1:]
  code = None; pkgs = []
  i = 0
  while i < len(args):
      a = args[i]
      if a == "-c" and i + 1 < len(args): code = args[i + 1]; i += 2
      else: pkgs.append(a); i += 1
  if not pkgs:
      sys.stderr.write("usage: install PKG... [-c CODE]\n"); sys.exit(2)
  import requests, urllib.error
  def _norm(n): return n.lower().replace("_", "-")
  def _get(url):
      # broker requests can transiently time out -> retry a few times before failing the whole stage.
      last = None
      for _ in range(5):
          try: return requests.get(url)
          except urllib.error.URLError as e: last = e
      raise last
  def _wheel(name):
      r = _get("https://pypi.org/pypi/%s/json" % name)
      if r.status_code != 200: return None, None
      d = r.json(); ver = d["info"]["version"]
      for f in d.get("releases", {}).get(ver, []):
          if f.get("packagetype") == "bdist_wheel" and "none-any" in f.get("filename", ""):
              return f["url"], ver
      return None, None
  installed = {}
  try:
      for name in pkgs:
          wheel, ver = _wheel(name)
          if not wheel:
              sys.stderr.write("skip (no pure-python wheel): %s\n" % name); continue
          blob = _get(wheel).content
          path = "/b/%s.whl" % _norm(name).replace("-", "_")
          open(path, "wb").write(blob)
          sys.path.insert(0, path); installed[_norm(name)] = ver
      # a freshly-installed real package must not be shadowed by a prelude shim of the same name.
      for n in list(installed): sys.modules.pop(n.replace("-", "_"), None)
      print("installed:", ", ".join("%s %s" % (k, v) for k, v in installed.items()))
      if code: exec(code)
      sys.exit(0)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      import traceback; traceback.print_exc(); sys.exit(1)
  """

  @pypi_scope ["pypi.org", "files.pythonhosted.org", "*.pythonhosted.org"]

  # curated parsing closure for pdm.models.requirements + pdm.models.specifiers (no virtualenv/rich/pygments —
  # those are CLI machinery, heavy, and not needed by the resolver-facing parsing surface).
  @closure ~w(pdm packaging dep-logic tomlkit resolvelib unearth httpx httpcore anyio idna certifi h11 sniffio exceptiongroup typing-extensions)

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("reclaim-pdm-install", @installer, :argv, %{allow: @pypi_scope})
    :ok
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "pdm resolver core: stage pure-python parsing closure + run real pdm parse APIs in-sandbox" do
    # mmap ModuleType stub (recipe), + a couple of attrs the broker `requests` shim lacks that unearth touches
    # at import time, then drive pdm's REAL requirement + specifier parsers.
    code =
      ~S"""
      import sys, types
      sys.modules.setdefault("mmap", types.ModuleType("mmap"))
      import requests
      if not hasattr(requests, "HTTPError"):
          requests.HTTPError = type("HTTPError", (Exception,), {})
      if not hasattr(requests, "RequestException"):
          requests.RequestException = type("RequestException", (Exception,), {})
      if not hasattr(requests, "Session"):
          requests.Session = type("Session", (), {})

      from pdm.models.requirements import parse_requirement
      from pdm.models.specifiers import PySpecSet

      req = parse_requirement("requests>=2.20,<3.0")
      print("PDM_REQ", req.key, str(req.specifier))

      spec = PySpecSet(">=3.8,<4.0")
      print("PDM_PYSPEC", spec.contains("3.11.0"), spec.contains("3.7.0"))
      """

    assert {:ok, out, 0} =
             CommandRegistry.run_status("reclaim-pdm-install", "", @closure ++ ["-c", code])

    # pdm's own wheel + its parsing-closure deps were fetched + zipimported over the broker
    assert out =~ "installed:" and out =~ "pdm " and out =~ "packaging" and out =~ "dep-logic"
    # real pdm requirement parser produced a normalized key + specifier (note: specifier set is order-normalized)
    assert out =~ ~r/PDM_REQ requests .*>=2\.20/ and out =~ "<3.0"
    # real pdm PySpecSet evaluates a python-version constraint correctly (3.11 in range, 3.7 out)
    assert out =~ "PDM_PYSPEC True False"
  end
end
