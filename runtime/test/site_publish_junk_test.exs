defmodule Workbooks.SitePublishJunkTest do
  use ExUnit.Case, async: false

  # Publish must never mirror OS metadata cruft: AppleDouble resource forks (._*)
  # committed by a macOS dev were polluting bit.ml's served tree (22 of them).
  # Real content still publishes; the junk is dropped.

  @data "/tmp/wb-publish-junk"

  setup do
    File.rm_rf!(@data)
    on_exit(fn -> File.rm_rf!(@data) end)
    System.put_env("WB_DATA", @data)
    System.delete_env("WB_PUBLIC_APP")
    :ok
  end

  test "deploy_app ships dist/ to the served root, clears stale assets, no-ops without dist" do
    workdir = Path.join(@data, "app")
    dest = Path.join([@data, "build/public/apptest"])

    # no dist yet → no-op
    File.mkdir_p!(workdir)
    assert {:ok, 0} = Workbooks.SitePublish.deploy_app(workdir, "apptest")

    # a stale asset already served (from a prior build) — must be cleared
    File.mkdir_p!(Path.join(dest, "assets"))
    File.write!(Path.join(dest, "assets/old-DEADBEEF.js"), "stale")

    # build output appears in the repo (CI committed it, or in-sandbox build)
    File.mkdir_p!(Path.join(workdir, "dist/assets"))
    File.write!(Path.join(workdir, "dist/index.html"), "<!doctype html><div id=app></div>")
    File.write!(Path.join(workdir, "dist/assets/index-NEW123.js"), "console.log('new')")

    assert {:ok, 2} = Workbooks.SitePublish.deploy_app(workdir, "apptest")
    assert File.exists?(Path.join(dest, "index.html"))
    assert File.exists?(Path.join(dest, "assets/index-NEW123.js"))
    # the stale bundle is gone (renamed-bundle hygiene)
    refute File.exists?(Path.join(dest, "assets/old-DEADBEEF.js"))
  end

  test "publish copies real content but drops ._AppleDouble and .DS_Store" do
    workdir = Path.join(@data, "repo")
    stories = Path.join(workdir, "content/stories")
    File.mkdir_p!(stories)

    File.write!(Path.join(stories, "real-story.org"), "#+TITLE: a real story\n")
    File.write!(Path.join(workdir, "content/stories.json"), "[{\"slug\":\"real-story\"}]")
    # the cruft that should never ship
    File.write!(Path.join(stories, "._real-story.org"), "applefork-junk")
    File.write!(Path.join(workdir, "content/._stories.json"), "applefork-junk")
    File.write!(Path.join(stories, ".DS_Store"), "ds-junk")

    assert {:ok, n} = Workbooks.SitePublish.publish(workdir, "junktest")

    dest = Path.join([@data, "build/public/junktest"])
    assert File.exists?(Path.join(dest, "content/stories/real-story.org"))
    assert File.exists?(Path.join(dest, "content/stories.json"))

    refute File.exists?(Path.join(dest, "content/stories/._real-story.org"))
    refute File.exists?(Path.join(dest, "content/._stories.json"))
    refute File.exists?(Path.join(dest, "content/stories/.DS_Store"))

    # exactly the 2 real files were counted
    assert n == 2
  end
end
