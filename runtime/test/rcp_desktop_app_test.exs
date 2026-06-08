defmodule RcpDesktopAppTest do
  @moduledoc """
  RCP-4 (wb-dl2): the `desktop-app` publish target emits a buildable, runtime-
  connected workbook app — frontend wired to the RCP connector, Tauri config from
  publish.org, pointed at the configured runtime.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Publish.DesktopApp
  alias Workbooks.Publish.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "wb_app_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    html_path = Path.join(dir, "index.html")
    File.write!(html_path, "<!doctype html><html><body><h1>hi</h1></body></html>")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, html: html_path}
  end

  test "scaffolds the connected app files", %{dir: dir, html: html} do
    props = %{"PUBLISH_APP_NAME" => "My Book", "PUBLISH_VERSION" => "2.3.0", "PUBLISH_URL" => "https://rt.example.com"}
    assert {:ok, %{files: files}} = DesktopApp.scaffold(html, props)
    assert "index.html" in files and "rcp.js" in files and "tauri.conf.json" in files

    # connector emitted + html imports it + exposes window.runtime
    assert File.exists?(Path.join(dir, "rcp.js"))
    page = File.read!(Path.join(dir, "index.html"))
    assert page =~ ~s(import { createClient } from "./rcp.js")
    assert page =~ "window.runtime = createClient"
    assert page =~ "https://rt.example.com"
    # bootstrap injected inside the body, app content preserved
    assert page =~ "<h1>hi</h1>"

    # tauri config carries publish.org metadata
    conf = Jason.decode!(File.read!(Path.join(dir, "tauri.conf.json")))
    assert conf["productName"] == "My Book"
    assert conf["version"] == "2.3.0"
    assert conf["identifier"] == "sh.workbooks.app.my-book"
    assert conf["build"]["frontendDist"] == "."
  end

  test "empty PUBLISH_URL → local discovery fallback in bootstrap", %{dir: dir, html: html} do
    assert {:ok, %{url: ""}} = DesktopApp.scaffold(html, %{"PUBLISH_APP_NAME" => "Local"})
    page = File.read!(Path.join(dir, "index.html"))
    assert page =~ "globalThis.__RCP_BASE__"
  end

  test "emitted rcp.js speaks the protocol (well-known + envelope + unavailable)", %{dir: dir, html: html} do
    {:ok, _} = DesktopApp.scaffold(html, %{"PUBLISH_APP_NAME" => "X"})
    js = File.read!(Path.join(dir, "rcp.js"))
    assert js =~ "/.well-known/workbooks-runtime"
    assert js =~ "class RcpError"
    assert js =~ ~s(authorization: "Bearer ")
    assert js =~ ~s|new RcpError("unavailable"|
  end

  test "public posture INLINES the rendered content", %{dir: dir, html: html} do
    assert {:ok, %{mode: :inline, posture: :public}} = DesktopApp.scaffold(html, %{"PUBLISH_APP_NAME" => "Pub"})
    assert File.read!(Path.join(dir, "index.html")) =~ "<h1>hi</h1>"
  end

  test "gated posture emits a SHELL with NO inlined content (anti-leak)", %{dir: dir, html: html} do
    assert {:ok, %{mode: :shell, posture: :gated_data}} =
             DesktopApp.scaffold(html, %{"PUBLISH_APP_NAME" => "Secret", "PUBLISH_ACCESS" => "gated-data", "PUBLISH_CONTENT_PATH" => "/api/w/secret/html"})

    page = File.read!(Path.join(dir, "index.html"))
    # the protected content from the rendered html is NOT baked into the artifact
    refute page =~ "<h1>hi</h1>"
    # instead it fetches it from the runtime post-auth, and degrades to a sign-in
    assert page =~ ~s|rt.request("/api/w/secret/html")|
    assert page =~ ~s(id="auth")
    assert page =~ "unauthorized"
  end

  test "desktop-app is a recognized target requiring an app name" do
    assert :ok = Config.validate(%{"PUBLISH_TARGET" => "desktop-app", "PUBLISH_APP_NAME" => "Z"})
    assert {:error, issues} = Config.validate(%{"PUBLISH_TARGET" => "desktop-app"})
    assert Enum.any?(issues, &(&1 =~ "desktop-app needs PUBLISH_APP_NAME"))
  end
end
