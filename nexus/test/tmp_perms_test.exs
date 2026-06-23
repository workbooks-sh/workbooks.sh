defmodule Nexus.TmpPermsTest do
  @moduledoc "Seam 2.1 / wb-xmld: per-job staging dirs are owner-only (0700), not world-readable."
  use ExUnit.Case, async: true
  import Bitwise

  test "mkdir_private! creates a 0700 dir" do
    dir = Path.join(System.tmp_dir!(), "wb-priv-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    assert ^dir = Nexus.Paths.mkdir_private!(dir)
    {:ok, %File.Stat{mode: mode}} = File.stat(dir)
    assert (mode &&& 0o777) == 0o700, "expected 0700, got #{Integer.to_string(mode &&& 0o777, 8)}"
  end
end
