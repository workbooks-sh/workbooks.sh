defmodule Nexus.HomeSurfaceTest do
  # async: false — reloads the global Nexus.Config.
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "home_#{System.unique_integer([:positive])}")
    # Deploy-as-index-tree: root index.work is the MANIFEST (not a surface); subfolders are surfaces.
    File.mkdir_p!(Path.join(dir, "lander/blog"))
    File.mkdir_p!(Path.join(dir, "cloud"))
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "index.work"), "# manifest\n")
    for s <- ["lander", "lander/blog", "cloud", "docs"],
        do: File.write!(Path.join([dir, s, "index.work"]), "app :#{Path.basename(s)} do\nend\n")

    on_exit(fn -> File.rm_rf!(dir); Nexus.Config.reload(nil) end)
    {:ok, dir: dir}
  end

  test "no home knob → surfaces keep their folder paths; nothing at root", %{dir: dir} do
    Nexus.Config.reload(nil)
    names = Nexus.Server.discover_mounts_for_test(dir) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert names == ["cloud", "docs", "lander", "lander/blog"]
    refute "" in names
  end

  test "home=lander rebases the lander subtree to root; others unchanged", %{dir: dir} do
    Nexus.Config.reload(~s(deploy do\n  home="lander"\nend))
    mounts = Nexus.Server.discover_mounts_for_test(dir)
    names = mounts |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    # lander → "" (the front door), lander/blog → "blog"; cloud/docs keep their paths.
    assert names == ["", "blog", "cloud", "docs"]

    # the "" mount points at the lander dir (so / serves the landing page)
    {"", home_dir} = Enum.find(mounts, fn {n, _} -> n == "" end)
    assert Path.basename(home_dir) == "lander"
  end

  test "home naming a missing surface is a safe no-op", %{dir: dir} do
    Nexus.Config.reload(~s(deploy do\n  home="nope"\nend))
    names = Nexus.Server.discover_mounts_for_test(dir) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert names == ["cloud", "docs", "lander", "lander/blog"]
  end
end
