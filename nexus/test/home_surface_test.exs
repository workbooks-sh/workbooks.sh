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

  test "a surface's SSR weave excludes nested child surfaces (no title/content leak)", %{dir: dir} do
    # lander/index.work declares its own title; blog (a nested surface) declares another. Rendering the
    # lander must NOT pull in the blog's files — its title/content stay the blog's own.
    # Real-lander shape: prose sections, no app block (so the weave renders the prose directly).
    File.write!(Path.join([dir, "lander", "index.work"]), "# Landing\n\nThe hero pitch goes here.\n")
    File.write!(Path.join([dir, "lander", "01-hero.work"]), "# Hero\n\nBuild your whole stack.\n")
    File.write!(Path.join([dir, "lander", "blog", "index.work"]), "# Workbooks Blog\n\nThe latest blog posts.\n")

    html = Nexus.SSR.render(Path.join(dir, "lander"), live: false)
    assert html =~ "The hero pitch goes here."
    refute html =~ "Workbooks Blog"
    refute html =~ "latest blog posts"
  end

  test "home naming a missing surface is a safe no-op", %{dir: dir} do
    Nexus.Config.reload(~s(deploy do\n  home="nope"\nend))
    names = Nexus.Server.discover_mounts_for_test(dir) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert names == ["cloud", "docs", "lander", "lander/blog"]
  end
end
