defmodule Workbooks.PublicWebTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  # friction #10 (lander-live): a complete HTML document is served verbatim,
  # while non-document fragment content gets wrapped in the doc shell.
  describe "static_page/2" do
    test "serves a complete HTML document verbatim (no double-wrap)" do
      html = "<!doctype html><html lang=\"en\"><head><title>Mine</title></head><body>hi</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "is case/whitespace tolerant about the doctype" do
      html = "\n  <!DOCTYPE HTML><html><body>x</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "a non-document fragment is wrapped in the doc shell" do
      out = Workbooks.PublicWeb.static_page("doc", "<work-doc title=\"Heading\">body</work-doc>")
      assert String.contains?(out, "Built with Workbooks")
      assert String.contains?(out, "<title>doc</title>")
      assert String.contains?(out, "<work-doc")
    end
  end

  # pages are PAGES, not files: clean URLs resolve, .html URLs retire via 301
  describe "clean URLs (serve_static)" do
    setup do
      case Workbooks.Domains.start_link(nil) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      dir = Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", "dev"])
      File.mkdir_p!(Path.join(dir, "learn"))
      File.write!(Path.join(dir, "index.html"), "<!doctype html><html><head></head><body>home</body></html>")
      File.write!(Path.join([dir, "learn", "workbook.html"]), "<!doctype html><html><head></head><body>lesson</body></html>")
      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    defp get_path(path) do
      conn(:get, path) |> Map.put(:host, "dev.apps.example") |> Workbooks.PublicWeb.call([])
    end

    test "extensionless URL serves the page" do
      conn = get_path("/learn/workbook")
      assert conn.status == 200
      assert conn.resp_body =~ "lesson"
    end

    test ".html URL 301s to the clean form" do
      conn = get_path("/learn/workbook.html")
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/learn/workbook"]
    end

    test "/index.html canonicalizes to /" do
      conn = get_path("/index.html")
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/"]
    end

    test "directory default still serves its index" do
      conn = get_path("/")
      assert conn.status == 200
      assert conn.resp_body =~ "home"
    end

    test "missing pages still 404" do
      assert get_path("/learn/nope").status == 404
    end
  end

  # wb-5vm: /_changes — public read-only change feed
  describe "GET /_changes" do
    setup do
      # /_changes only needs Domains.resolve/1 (GenServer) + Git.log/1 (pure shell).
      # Handle already_started in case another test in the suite started Domains.
      case Workbooks.Domains.start_link(nil) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    test "returns JSON with a 'changes' key when app resolves via host" do
      # Use a host whose leftmost DNS label is a valid tenant name ("dev" is the
      # default primary tenant with a resolvable repo via Git.log/1). Domains
      # falls back to the leftmost label when there is no explicit registration.
      conn =
        conn(:get, "/_changes")
        |> Map.put(:host, "dev.apps.example")
        |> Workbooks.PublicWeb.call([])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "changes")
      assert is_list(body["changes"])
    end

    test "404s when Domains cannot resolve an app (empty host — no label)" do
      # Domains.resolve/1 falls back to first_label; an empty string has no label
      # and returns nil, which is the only path that produces a 404 from /_changes.
      conn =
        conn(:get, "/_changes")
        |> Map.put(:host, "")
        |> Workbooks.PublicWeb.call([])

      assert conn.status == 404
    end
  end
end
