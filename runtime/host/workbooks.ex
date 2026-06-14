defmodule Workbooks do
  @moduledoc """
  The Workbook Runtime — one OTP app. A Workbook (HTML + Org + state) docks here
  and runs as an isolated WASM Instance. Everything heavy is a dependency; this
  code is glue + orchestration. See CLEAN-ROOM.org.

  The runnable showcase lives in `Workbooks.Demos.*` (Kernel / Runtime / Build /
  Platform) — each `demo_*` exercises one capability end to end (the "everything
  stays wired" proof).
  """

  @doc """
  Deploy a Workbook: write it to the fast SQLite index AND commit it to the
  tenant's git repo (the versioned source of truth). Every deploy = one commit.
  """
  def deploy(id, org, tenant \\ "dev") do
    :ok = Workbooks.ControlPlane.put_workbook(id, org, tenant)
    Workbooks.Git.save(Workbooks.Git.identity(tenant), id, org)
  end
end
