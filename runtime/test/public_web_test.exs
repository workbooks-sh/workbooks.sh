defmodule Workbooks.PublicWebTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  # friction #10 (lander-live): a complete HTML document is served verbatim,
  # while org-source still gets the kernel render + doc shell.
  describe "static_page/2" do
    test "serves a complete HTML document verbatim (no double-wrap)" do
      html = "<!doctype html><html lang=\"en\"><head><title>Mine</title></head><body>hi</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "is case/whitespace tolerant about the doctype" do
      html = "\n  <!DOCTYPE HTML><html><body>x</body></html>"
      assert Workbooks.PublicWeb.static_page("app", html) == html
    end

    test "org-source is rendered and wrapped in the doc shell" do
      out = Workbooks.PublicWeb.static_page("doc", "* Heading\nbody")
      assert String.contains?(out, "Rendered by the Workbooks OQL kernel")
      assert String.contains?(out, "<title>doc</title>")
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
