defmodule Workbooks.Reclaim.PoetryTest do
  @moduledoc """
  RECLAIM (Poetry): durable proof of poetry-core (Poetry's pure-Python build backend)
  installing + running in-sandbox via pip-run.

  The full `poetry` CLI is off-the-table (native-extension deps, virtualenv subprocess,
  PEP 517 build subprocess). What run1 proved LIVE is the build-system ESSENCE: poetry-core
  installs and `Factory().create_poetry()` parses a real pyproject.toml and resolves the
  declared name/version/dependencies.

  The recipe's key subtlety, reproduced exactly here: pip-run's default install does
  `sys.path.insert(0, wheel.whl)` (zipimport), but zipimport CANNOT resolve PEP-420
  implicit-namespace packages, and poetry-core ships `poetry/core` with NO
  `poetry/__init__.py`. So inside pip-run's `-c CODE` we fetch the none-any wheel, do
  `zipfile.extractall()` into the preopened /tmp dir, then `sys.path.insert(0, dir)` —
  CPython's filesystem FileFinder DOES support implicit namespace packages, so
  `import poetry.core` then works. We then parse a real pyproject.toml.

  NOT reproduced (and not claimed): the `poetry` CLI, lockfile resolution from PyPI,
  virtualenv/PEP-517 subprocess builds. Only the pure-Python build-backend essence.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    Workbooks.BrokeredTools.register_all()
    :ok
  end

  # Driven inside pip-run's -c: extract the poetry-core wheel into /tmp (filesystem path, so
  # PEP-420 namespace import works) instead of zipimporting it, then parse a real pyproject.toml
  # with Factory().create_poetry() — proving the build-system essence is live.
  @code ~S"""
  import sys, io, zipfile, requests, os
  # poetry-core ships a none-any (pure-python) wheel; grab the wheel URL from PyPI.
  d = requests.get("https://pypi.org/pypi/poetry-core/json").json()
  ver = d["info"]["version"]
  wheel_url = None
  for f in d["releases"][ver]:
      if f["packagetype"] == "bdist_wheel" and "none-any" in f["filename"]:
          wheel_url = f["url"]; break
  assert wheel_url, "no none-any wheel for poetry-core"
  blob = requests.get(wheel_url).content
  dest = "/tmp/poetry_core_pkg"
  os.makedirs(dest, exist_ok=True)
  zipfile.ZipFile(io.BytesIO(blob)).extractall(dest)
  # filesystem FileFinder resolves the PEP-420 namespace pkg (poetry/core, no poetry/__init__.py)
  sys.path.insert(0, dest)
  # drop any shim of the same top-level name
  for m in list(sys.modules):
      if m == "poetry" or m.startswith("poetry."):
          sys.modules.pop(m, None)
  import poetry.core
  print("POETRY_CORE_VERSION", getattr(poetry.core, "__version__", ver))

  # Now drive the build-system essence: parse a REAL pyproject.toml and resolve its
  # declared name/version/dependencies via the Poetry factory.
  proj = "/tmp/sampleproj"
  os.makedirs(proj, exist_ok=True)
  open(os.path.join(proj, "pyproject.toml"), "w").write('''
  [tool.poetry]
  name = "reclaim-sample"
  version = "1.2.3"
  description = "a sample project parsed by poetry-core"
  authors = ["Reclaim <r@example.com>"]

  [tool.poetry.dependencies]
  python = "^3.10"
  requests = "^2.31"
  rich = ">=13.0"

  [build-system]
  requires = ["poetry-core"]
  build-backend = "poetry.core.masonry.api"
  ''')
  from poetry.core.factory import Factory
  po = Factory().create_poetry(proj)
  pkg = po.package
  print("NAME", pkg.name)
  print("VERSION", str(pkg.version))
  deps = sorted({d.name for d in pkg.requires})
  print("DEPS", ",".join(deps))
  """

  @tag :netdeps
  @tag timeout: 300_000
  test "poetry-core installs in-sandbox (PEP-420 extractall workaround) + parses a real pyproject.toml" do
    assert {:ok, out, 0} = CommandRegistry.run_status("pip-run", "", ["poetry-core", "-c", @code]),
           "pip-run poetry-core did not exit 0"

    # the namespace-package import worked
    assert out =~ ~r/POETRY_CORE_VERSION \d+\./, "poetry.core import failed:\n#{out}"

    # Factory().create_poetry() actually parsed the project metadata
    assert out =~ "NAME reclaim-sample", "factory did not parse project name:\n#{out}"
    assert out =~ "VERSION 1.2.3", "factory did not parse version:\n#{out}"

    # and resolved the declared dependencies (the build-system essence of Poetry)
    assert out =~ ~r/DEPS .*requests/, "factory did not resolve dependencies:\n#{out}"
    assert out =~ ~r/DEPS .*rich/, "factory did not resolve the rich dependency:\n#{out}"
  end
end
