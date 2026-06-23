defmodule Nexus.WorkspacesCopyCleanTest do
  @moduledoc """
  Round 3 finding: a general-agent staging copy walked the tree with copy_clean, which only skipped
  .git/.jj — so a misresolved root copied the multi-GB compilers/ tree and filled the disk. copy_clean
  now also skips runtime/build dirs (.nexus, compilers, _build, deps, node_modules).
  """
  use ExUnit.Case, async: true

  test "staging copies working files but skips VCS + build/runtime dirs" do
    base = Path.join(System.tmp_dir!(), "wb-cc-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    dst = Path.join(base, "dst")
    on_exit(fn -> File.rm_rf(base) end)

    File.mkdir_p!(src)
    File.write!(Path.join(src, "index.work"), "A surface.")
    File.mkdir_p!(Path.join(src, "brief"))
    File.write!(Path.join(src, "brief/launch.work"), "Brief.")
    # Things that must NOT be staged:
    for d <- ~w(.git .jj .nexus compilers _build deps node_modules) do
      File.mkdir_p!(Path.join(src, d))
      File.write!(Path.join([src, d, "junk"]), "heavy")
    end

    Nexus.Workspaces.copy_clean_for_test(src, dst)

    assert File.exists?(Path.join(dst, "index.work"))
    assert File.exists?(Path.join(dst, "brief/launch.work"))
    for d <- ~w(.git .jj .nexus compilers _build deps node_modules) do
      refute File.exists?(Path.join(dst, d)), "#{d} should have been skipped by copy_clean"
    end
  end
end
