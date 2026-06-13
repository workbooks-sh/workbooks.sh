defmodule Workbooks.BrokeredPkgInstallTest do
  @moduledoc """
  EMPIRICAL verification of the pure-Python LIBRARY-install capability — the reclaim of the heavy-pure-Python
  ecosystem. `pip-run` resolves + installs (brokered HTTPS download + zipimport) a real package's full dependency
  tree and imports it. Proves, by actually running each through the sandbox, that the packages the campaign
  flipped reachable→live genuinely install + import. (Networking inside them routes through the broker shim;
  real _ssl/threads/fork are absent — see the per-item notes in resolved.json for what's library-live vs
  CLI/server-limited.)

  These are the regression guards: if the fuel budget, the /tmp preopen, or the ssl/urllib/requests shims
  regress, these break — so "this package is live" stays empirically true going forward.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    Workbooks.BrokeredTools.register_all()
    :ok
  end

  # install PACKAGE (+ deps) and run a small import-and-use snippet; assert the version line appears + exit 0.
  defp pkg_imports(pkg, code, marker) do
    assert {:ok, out, 0} = CommandRegistry.run_status("pip-run", "", [pkg, "-c", code])
    assert out =~ marker, "expected #{inspect(marker)} in:\n#{out}"
    out
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "httpie installs + imports (heavy HTTP-client library; uses requests via the broker shim)" do
    pkg_imports("httpie", "import httpie; print('HTTPIE', httpie.__version__)", ~r/HTTPIE \d+\./)
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "yt-dlp installs + imports (heavy; needs the ssl stub to import past its TLS probing)" do
    pkg_imports("yt-dlp", "import yt_dlp; print('YTDLP', yt_dlp.version.__version__)", ~r/YTDLP \d+\./)
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "rich installs + imports + RENDERS (a non-trivial pure-Python library actually doing work)" do
    out =
      pkg_imports(
        "rich",
        "from rich.console import Console; from io import StringIO; c=Console(file=StringIO(), force_terminal=False); c.print('[bold]hi[/bold] world'); print('RICH', c.file.getvalue().strip())",
        ~r/RICH/
      )

    assert out =~ "hi world"
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "pip installs + imports (the installer library itself is importable)" do
    pkg_imports("pip", "import pip; print('PIP', pip.__version__)", ~r/PIP \d+\./)
  end
end
