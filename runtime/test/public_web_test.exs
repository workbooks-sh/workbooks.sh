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

  # wb-mv3d: CSP nonce-gating + sandboxed-iframe isolation of author content.
  describe "CSP / sandboxing (wb-mv3d)" do
    setup do
      case Workbooks.Domains.start_link(nil) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      dir = Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", "dev"])
      File.mkdir_p!(dir)
      # An author "one-file" workbook that tries to read same-origin cookies.
      File.write!(
        Path.join(dir, "index.html"),
        "<!doctype html><html><head></head><body><script>document.cookie</script>hi</body></html>"
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    defp csp_for(path) do
      conn = conn(:get, path) |> Map.put(:host, "dev.apps.example") |> Workbooks.PublicWeb.call([])
      {conn, get_resp_header(conn, "content-security-policy") |> List.first()}
    end

    test "served HTML never carries script-src 'unsafe-inline'" do
      {_conn, csp} = csp_for("/")
      assert csp =~ "script-src 'self' 'nonce-"
      refute csp =~ "script-src 'self' 'unsafe-inline'"
    end

    test "a published author page is served inside a sandboxed iframe (opaque origin)" do
      {conn, csp} = csp_for("/")
      assert conn.status == 200
      # The author's <script> is NOT inlined into the carrier — it rides in srcdoc.
      assert conn.resp_body =~ ~s(<iframe sandbox=")
      assert conn.resp_body =~ "allow-scripts"
      # crucially WITHOUT allow-same-origin → opaque origin, no serving-origin session
      refute conn.resp_body =~ "allow-same-origin"
      # the author's document rides INSIDE the srcdoc attribute (the iframe is the
      # last top-level element); it is not live markup in the carrier document.
      assert conn.resp_body =~ ~s(srcdoc=")
      [_carrier_head, after_iframe] = String.split(conn.resp_body, ~s(srcdoc="), parts: 2)
      assert after_iframe =~ "document.cookie"
      # any double-quote in the author doc is entity-escaped so it can't close srcdoc
      refute String.contains?(after_iframe |> String.split(~s("></iframe>)) |> hd(), "\"")
      assert csp =~ "frame-src 'self'"
    end

    test "host-rendered org shell nonces its loader and drops unsafe-inline" do
      # No site dir → control-plane render path. Use a tenant with no published dir.
      File.rm_rf!(Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", "dev"]))
      nonce = "TESTNONCE=="
      shell = Workbooks.PublicWeb.static_doc("doc", "<p>x</p>", nonce)
      assert shell =~ ~s(<script id="wb-bundle-loader" nonce="#{nonce}">)
    end

    test "static_doc without a nonce emits a bare loader (offline/file:// path)" do
      shell = Workbooks.PublicWeb.static_doc("doc", "<p>x</p>")
      assert shell =~ ~s(<script id="wb-bundle-loader">)
      refute shell =~ "nonce="
    end
  end

  # wb-mv3d regression guard: hardening must NOT break the host's own docs/learn
  # shelf. A trusted host-built site page (carries the carrier marker) is still
  # sandboxed (opaque origin) but its CSP permits its first-party inline scripts +
  # the mermaid ESM module from jsdelivr; an UNTRUSTED author page stays tight.
  describe "trusted host docs page vs untrusted author page (wb-mv3d regression)" do
    setup do
      case Workbooks.Domains.start_link(nil) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      dir = Path.join([System.get_env("WB_DATA") || File.cwd!(), "build", "public", "dev"])
      File.mkdir_p!(Path.join(dir, "learn"))
      # A host-built site page (marker baked in by site_page) with inline scripts.
      host_page = Workbooks.PublicWeb.site_page("Lesson", "<p>body</p>", "<nav></nav>", "/learn/x", "Docs")
      File.write!(Path.join([dir, "learn", "x.html"]), host_page)
      # An untrusted author page (no marker) with an inline script.
      File.write!(
        Path.join(dir, "author.html"),
        "<!doctype html><html><head></head><body><script>document.cookie</script>a</body></html>"
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    defp csp_at(path) do
      conn = conn(:get, path) |> Map.put(:host, "dev.apps.example") |> Workbooks.PublicWeb.call([])
      {conn, get_resp_header(conn, "content-security-policy") |> List.first()}
    end

    test "site_page bakes in the host carrier marker (the trust discriminator)" do
      page = Workbooks.PublicWeb.site_page("T", "<p>b</p>", "<nav></nav>", "/x", "S")
      assert String.contains?(page, "Served by the Workbooks runtime")
    end

    test "trusted host docs page: CSP allows first-party inline scripts + jsdelivr ESM" do
      {conn, csp} = csp_at("/learn/x")
      assert conn.status == 200
      # still isolated in an opaque-origin iframe
      assert conn.resp_body =~ ~s(<iframe sandbox=")
      refute conn.resp_body =~ "allow-same-origin"
      # but the docs carrier lets its OWN scripts + mermaid run
      assert csp =~ "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net"
      assert csp =~ "connect-src 'self' https://cdn.jsdelivr.net"
      # no nonce in script-src (a nonce would make browsers ignore 'unsafe-inline')
      refute csp =~ "script-src 'self' 'nonce-"
    end

    test "untrusted author page: tight nonce policy, no unsafe-inline, no CDN" do
      {conn, csp} = csp_at("/author")
      assert conn.status == 200
      assert conn.resp_body =~ ~s(<iframe sandbox=")
      assert csp =~ "script-src 'self' 'nonce-"
      refute csp =~ "script-src 'self' 'unsafe-inline'"
      refute csp =~ "jsdelivr"
    end
  end

end
