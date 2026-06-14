defmodule Workbooks.WorkdirConfinementTest do
  @moduledoc """
  Workdir confinement (wb-g1yo.4b): a CLOUD/shared caller's agent run must NOT use
  a caller-supplied host path (path-traversal / cross-tenant FS) — it's confined
  to a per-tenant scratch root. The trusted DESKTOP keeps its local workbook path.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Web

  test "cloud caller (not desktop): a malicious workdir is IGNORED → per-tenant scratch" do
    wd = Web.confined_workdir(false, "alice", "run-1", "/etc/evil")
    refute wd == "/etc/evil"
    assert wd =~ "/wb-runs/alice/run-1"
    # different tenant → different root, no cross-tenant overlap
    bob = Web.confined_workdir(false, "bob", "run-1", "/etc/evil")
    assert bob =~ "/wb-runs/bob/run-1"
    refute wd == bob
  end

  test "cloud caller with no workdir also gets a confined scratch" do
    assert Web.confined_workdir(false, "alice", "run-2", nil) =~ "/wb-runs/alice/run-2"
  end

  test "weird tenant chars are sanitized into the path (no traversal via tenant)" do
    wd = Web.confined_workdir(false, "../../etc", "run-3", nil)
    refute wd =~ "/etc/run-3"
    assert wd =~ "wb-runs"
    refute wd =~ ".."
  end

  test "DESKTOP (trusted): keeps the requested local workbook path" do
    assert Web.confined_workdir(true, "local", "run-4", "/Users/me/workbook") == "/Users/me/workbook"
    # desktop with no requested path still falls back to a scratch (safe default)
    assert Web.confined_workdir(true, "local", "run-5", nil) =~ "/wb-runs/local/run-5"
  end
end
