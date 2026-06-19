defmodule Nexus.StaticAssetTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  @opts Nexus.Server.init([])

  setup do
    dir = Path.join(System.tmp_dir!(), "wbstatic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "site/fonts"))
    File.write!(Path.join(dir, "site/index.work"), "# Site\n\nsome source\n")
    File.write!(Path.join(dir, "site/fonts/x.css"), "body{color:red}")
    File.write!(Path.join(dir, "site/logo.svg"), "<svg/>")
    # a file OUTSIDE the mount — the traversal target that must never be reachable
    File.write!(Path.join(dir, "secret.txt"), "TOPSECRET")
    Application.put_env(:nexus, :mounts, [{"site", Path.join(dir, "site")}])
    on_exit(fn -> Application.delete_env(:nexus, :mounts); File.rm_rf!(dir) end)
    :ok
  end

  defp req(path), do: Nexus.Server.call(conn(:get, path), @opts)

  test "serves a static asset with the right MIME type" do
    c = req("/site/fonts/x.css")
    assert c.status == 200
    assert c.resp_body == "body{color:red}"
    assert hd(get_resp_header(c, "content-type")) =~ "text/css"
  end

  test "serves an svg with image/svg+xml" do
    c = req("/site/logo.svg")
    assert c.status == 200
    assert hd(get_resp_header(c, "content-type")) =~ "image/svg+xml"
  end

  test "SECURITY: path traversal cannot escape the mount" do
    for p <- ["/site/%2e%2e/secret.txt", "/site/..%2fsecret.txt", "/site/fonts/%2e%2e/%2e%2e/secret.txt"] do
      c = req(p)
      refute c.resp_body == "TOPSECRET", "traversal leaked via #{p}"
    end
  end

  test ".work is NOT served as a raw static file — it renders as HTML (source stays behind /source)" do
    c = req("/site/index.work")
    # rendered workbook (text/html), not the raw .work bytes served as a download
    assert Enum.any?(get_resp_header(c, "content-type"), &(&1 =~ "text/html"))
    assert c.resp_body =~ "<!doctype html>"
  end

  test "a missing asset is not served as a file (no asset content-type)" do
    c = req("/site/nope.png")
    refute Enum.any?(get_resp_header(c, "content-type"), &(&1 =~ "image/png"))
  end
end
