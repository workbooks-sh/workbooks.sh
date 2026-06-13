defmodule Workbooks.Reclaim.BuildoutTest do
  @moduledoc """
  RECLAIM: Buildout (zc.buildout) — pure-Python install lane + real config engine, in-sandbox.

  Self-contained reproduction of the prior agent's recipe:
    * register the `pip-run` install lane INLINE (fetch pure-python wheels over the brokered
      pypi transport, zipimport them onto sys.path under /b);
    * `pip-run zc.buildout -c CODE` installs zc.buildout + its dep closure (setuptools/packaging/
      zc.recipe.egg etc) as wheels;
    * because `zc` is a PEP-420 namespace package zipimport won't auto-expose, the test reads
      zc/buildout/configparser.py out of /b/zc.buildout.whl with zipfile, exec-compiles it, and
      drives its parse() on a real buildout.cfg → resolving parts / recipes / options.

  This proves zc.buildout actually installed from PyPI AND that its config engine parses a real
  buildout.cfg in-sandbox. It does NOT claim the full `bin/buildout` egg-install runs.

  @tag :netdeps — needs network to reach pypi.org / files.pythonhosted.org.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  @pypi_scope ["pypi.org", "files.pythonhosted.org", "*.pythonhosted.org"]

  # The pip-run install lane, inlined verbatim from the brokered-tools recipe so the test owns it.
  @pip_run ~S"""
  import sys, json, re
  args = sys.argv[1:]
  pkg = None; code = None; max_pkgs = 100; max_mb = 200
  i = 0
  while i < len(args):
      a = args[i]
      if a == "-c" and i + 1 < len(args): code = args[i + 1]; i += 2
      elif a == "--max-pkgs" and i + 1 < len(args): max_pkgs = int(args[i + 1]); i += 2
      elif a == "--max-mb" and i + 1 < len(args): max_mb = int(args[i + 1]); i += 2
      elif pkg is None: pkg = a; i += 1
      else: i += 1
  if not pkg:
      sys.stderr.write("usage: pip-run PACKAGE [-c CODE]\n"); sys.exit(2)
  import requests, urllib.error

  class _Cap(Exception): pass
  installed = {}; total = [0]
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
              if "extra ==" in marker:
                  continue
          else:
              req = r
          m = re.match(r"\s*([A-Za-z0-9_.\-]+)", req)
          if m: out.append(m.group(1))
      return out

  def _install(name):
      n = _norm(name)
      if n in installed: return
      if len(installed) >= max_pkgs:
          raise _Cap("package cap exceeded (max %d)" % max_pkgs)
      wheel, ver, rd = _meta(name)
      if not wheel:
          sys.stderr.write("skip (no pure-python wheel): %s\n" % name); return
      blob = requests.get(wheel).content
      total[0] += len(blob)
      if total[0] > max_mb * 1024 * 1024:
          raise _Cap("download byte cap exceeded (max %d MB)" % max_mb)
      path = "/b/%s.whl" % n.replace("-", "_")
      open(path, "wb").write(blob)
      sys.path.insert(0, path); installed[n] = ver
      for d in _deps(rd):
          _install(d)

  try:
      _install(pkg)
      if not installed:
          sys.stderr.write("not found / no pure-python wheel: %s\n" % pkg); sys.exit(3)
      for n in list(installed):
          sys.modules.pop(n.replace("-", "_"), None)
      print("installed:", ", ".join("%s %s" % (k, v) for k, v in installed.items()))
      if code:
          exec(code)
      else:
          __import__(pkg.replace("-", "_"))
          print("import ok:", pkg)
      sys.exit(0)
  except _Cap as e:
      print("CAP:", e); sys.exit(4)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      sys.stderr.write("error: %s\n" % e); sys.exit(1)
  """

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("reclaim-pip-run", @pip_run, :argv, %{allow: @pypi_scope})
    :ok
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "zc.buildout installs from PyPI and its config engine parses a real buildout.cfg in-sandbox" do
    # A real-world buildout.cfg: a [buildout] section with parts, plus a part bound to a recipe with options.
    cfg = """
    [buildout]
    parts = py demo
    develop = .

    [py]
    recipe = zc.recipe.egg
    eggs = requests
    interpreter = py

    [demo]
    recipe = zc.recipe.egg:scripts
    eggs = ${py:eggs}
    extra = hello
    """

    # Drive the parse INSIDE the sandbox: install zc.buildout, then read its configparser.py out of the
    # wheel zip, exec-compile it, and parse(io.StringIO(cfg)). Print the resolved structure so the host asserts.
    code = ~s"""
    import zipfile, io, types, sys, glob, os
    cfg = #{inspect(cfg)}
    # the install lane writes the wheel as /b/<norm>.whl where norm only replaces '-' (not '.'),
    # so zc.buildout lands at /b/zc.buildout.whl. Find it defensively either way.
    cands = [p for p in glob.glob("/b/*.whl") if "buildout" in os.path.basename(p)]
    if not cands:
        sys.stderr.write("no buildout wheel found in /b: %s\\n" % glob.glob("/b/*.whl")); sys.exit(8)
    whl = cands[0]
    src = None
    z = zipfile.ZipFile(whl)
    for n in z.namelist():
        if n.endswith("zc/buildout/configparser.py"):
            src = z.read(n).decode(); break
    if src is None:
        sys.stderr.write("configparser.py not found in wheel\\n"); sys.exit(7)
    mod = types.ModuleType("zc_buildout_configparser")
    exec(compile(src, "configparser.py", "exec"), mod.__dict__)
    data = mod.parse(io.StringIO(cfg), "buildout.cfg")
    # data: {section: {option: value}}
    parts = data["buildout"]["parts"].split()
    print("SECTIONS", " ".join(sorted(data.keys())))
    print("PARTS", " ".join(parts))
    print("PY_RECIPE", data["py"]["recipe"])
    print("DEMO_RECIPE", data["demo"]["recipe"])
    print("DEMO_EXTRA", data["demo"]["extra"])
    print("OK")
    """

    {:ok, out, status} =
      CommandRegistry.run_status("reclaim-pip-run", "", ["zc.buildout", "-c", code])

    # If the network/wheel lane is unavailable, surface it loudly rather than silently passing.
    assert status == 0, "pip-run zc.buildout failed (status #{status}):\n#{out}"

    assert out =~ "installed: ", "no package install line — install lane did not run:\n#{out}"
    assert out =~ "zc.buildout ", "zc.buildout itself did not install:\n#{out}"

    # The config engine genuinely parsed the cfg:
    assert out =~ "PARTS py demo", "parts not resolved:\n#{out}"
    assert out =~ "PY_RECIPE zc.recipe.egg"
    assert out =~ "DEMO_RECIPE zc.recipe.egg:scripts"
    assert out =~ "DEMO_EXTRA hello"
    assert out =~ ~r/\nOK\n?$/
  end
end
