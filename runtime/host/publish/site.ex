defmodule Workbooks.Publish.Site do
  @moduledoc """
  Multi-page site mode for wb publish. Reads a site.org manifest, renders
  each linked org file with a shared sidebar, outputs a flat dist/.

  site.org format:
    #+TITLE: Site Name
    #+PUBLISH_TARGET: cloudflare-pages
    #+PUBLISH_PROJECT: my-project
    #+PUBLISH_DOMAIN: docs.example.com
    #+PUBLISH_CF_ACCOUNT: <account_id>   (optional)

    * Section Title
      - [[path/to/page.org][Page Title]]
      - [[path/to/page2.org][Another Page]]

    * Another Section
      - [[reference/cli.org][CLI Reference]]

  Each #+KEYWORD: line maps to a config key (same names as publish.org properties,
  minus the PUBLISH_ prefix for TITLE/TARGET/PROJECT/DOMAIN; full names also work).
  Pages are org link items under * section headings. All paths are relative to the
  directory containing site.org.
  """
  alias Workbooks.PublicWeb

  # ---- public API -----------------------------------------------------------

  @doc "Build a site from a directory containing site.org → dist/ in that dir."
  def build(site_dir) do
    with {:ok, manifest} <- parse(site_dir),
         :ok <- render_all(manifest) do
      ship(manifest)
    end
  end

  @doc "Parse site.org from a directory → manifest map."
  def parse(site_dir) do
    path = Path.join(site_dir, "site.org")

    case File.read(path) do
      {:ok, body} ->
        config = parse_keywords(body)
        sections = parse_nav(body)
        {:ok, %{config: config, sections: sections, dir: site_dir}}

      {:error, e} ->
        {:error, "cannot read #{path}: #{:file.format_error(e)}"}
    end
  end

  # ---- parsing --------------------------------------------------------------

  # #+KEYWORD: value lines → string-keyed map.
  # Accepts both PUBLISH_TARGET and TARGET (normalises to PUBLISH_* internally).
  defp parse_keywords(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^#\+([A-Za-z_]+):\s*(.+)$/, String.trim(line)) do
        [_, k, v] ->
          key = normalise_key(String.upcase(k))
          Map.put(acc, key, String.trim(v))

        _ ->
          acc
      end
    end)
  end

  defp normalise_key(k) when k in ~w(TITLE TARGET PROJECT DOMAIN CF_ACCOUNT OUTPUT URL),
    do: "PUBLISH_" <> k

  defp normalise_key(k), do: k

  # Walk lines: * headings → sections; - [[file][title]] items → pages.
  defp parse_nav(body) do
    lines = String.split(body, "\n")

    {sections, _current_idx} =
      Enum.reduce(lines, {[], nil}, fn line, {sects, idx} ->
        t = String.trim(line)

        cond do
          # * Section heading (no link — pure label)
          match = Regex.run(~r/^\*\s+([^\[].*)$/, t) ->
            [_, title] = match
            {sects ++ [%{title: title, pages: []}], length(sects)}

          # * [[file.org][Title]] — standalone page as its own section
          match = Regex.run(~r/^\*\s+\[\[([^\]]+)\]\[([^\]]+)\]\]/, t) ->
            [_, file, title] = match
            section = %{title: nil, pages: [page_entry(file, title)]}
            {sects ++ [section], length(sects)}

          # - [[file.org][Title]] or  • [[...][...]] — page item
          # bind `match` first so it is always defined; short-circuit can't leave it unbound
          (match = Regex.run(~r/\[\[([^\]]+\.org)\]\[([^\]]+)\]\]/, t)) && idx != nil ->
            [_, file, title] = match
            updated = update_in(sects, [Access.at(idx), :pages], &(&1 ++ [page_entry(file, title)]))
            {updated, idx}

          true ->
            {sects, idx}
        end
      end)

    # Drop empty sections (e.g. the #+KEYWORD header block accidentally parsed)
    Enum.filter(sections, fn s -> s.pages != [] end)
  end

  defp page_entry(file, title) do
    %{file: file, title: title, url: org_to_url(file)}
  end

  # getting-started/installation.org → getting-started/installation.html
  defp org_to_url(file), do: Regex.replace(~r/\.org$/, file, ".html")

  # ---- rendering ------------------------------------------------------------

  defp render_all(%{sections: sections, dir: dir, config: config}) do
    pages = Enum.flat_map(sections, & &1.pages)
    base = config["PUBLISH_BASE_PATH"] || ""
    nav_html = build_nav_html(sections, config, base)

    errors =
      Enum.flat_map(pages, fn page ->
        org_path = Path.join(dir, page.file)
        out_path = Path.join([dir, "dist", page.url])

        case render_page(org_path, page.title, nav_html, page.url, config) do
          {:ok, html} ->
            File.mkdir_p!(Path.dirname(out_path))
            File.write!(out_path, html)
            []

          {:error, msg} ->
            ["#{page.file}: #{msg}"]
        end
      end)

    if errors == [], do: :ok, else: {:error, Enum.join(errors, "\n")}
  end

  defp render_page(org_path, title, nav_html, current_url, config) do
    case File.read(org_path) do
      {:ok, org} ->
        body_html = Workbooks.OQL.render(org)
        site_title = config["PUBLISH_TITLE"] || "Workbooks"
        {:ok, PublicWeb.site_page(title, body_html, nav_html, current_url, site_title)}

      {:error, e} ->
        {:error, "cannot read #{org_path}: #{:file.format_error(e)}"}
    end
  end

  # Build sidebar nav HTML. Current page gets `aria-current="page"`.
  defp build_nav_html(sections, config, base \\ "") do
    site_title = config["PUBLISH_TITLE"] || "Workbooks"
    home = if base == "", do: "/index.html", else: "#{base}/index.html"

    items =
      Enum.map_join(sections, "\n", fn section ->
        label = if section.title, do: ~s(<p class="nav-label">#{esc(section.title)}</p>), else: ""

        links =
          Enum.map_join(section.pages, "\n", fn page ->
            href = if base == "", do: "/#{page.url}", else: "#{base}/#{page.url}"
            ~s(<li><a href="#{href}" data-url="#{page.url}">#{esc(page.title)}</a></li>)
          end)

        "#{label}<ul>#{links}</ul>"
      end)

    dna =
      [3, 5, 2, 6, 4, 3, 7, 2, 5, 4, 6, 3, 2, 5, 4, 7, 3, 5, 2, 6]
      |> Enum.with_index()
      |> Enum.map_join("", fn {w, i} ->
        c = Enum.at(~w(#a8d4f0 #aee5c2 #f3c5a3 #f2ddb0 #d9c5f0 #f0b8b8 #b8e0e8), rem(i, 7))
        ~s(<i style="flex:#{w};background:#{c};animation-delay:#{Float.round(i * 0.35, 2)}s"></i>)
      end)

    """
    <nav class="sidebar" id="sidebar">
      <div class="dnastrip" aria-hidden="true">#{dna}</div>
      <div class="sidebar-head">
        <span class="brand-mark"></span>
        <a href="/" class="sidebar-title" title="Back to workbooks.sh">workbooks</a>
        <a href="#{home}" class="sidebar-sub sidebar-sub-link">docs</a>
        <button class="sidebar-close" onclick="toggleSidebar()" aria-label="Close menu">✕</button>
      </div>
      <div class="nav-body">
        #{items}
      </div>
    </nav>
    """
  end

  # ---- shipping -------------------------------------------------------------

  defp ship(%{config: config, dir: dir}) do
    target = config["PUBLISH_TARGET"]
    dist = Path.join(dir, "dist")

    case target do
      "cloudflare-pages" -> ship_cloudflare(dist, config)
      "gh-pages" -> ship_gh_pages(dist, config)
      "self-hosted" -> {:error, "self-hosted not supported for site mode yet", %{}}
      nil -> {:ok, "built → #{dist} (no PUBLISH_TARGET set — skipping deploy)", %{dist: dist}}
      other -> {:error, "unknown PUBLISH_TARGET: #{other}", %{}}
    end
  end

  defp ship_cloudflare(dist, config) do
    project = config["PUBLISH_PROJECT"]
    domain = config["PUBLISH_DOMAIN"]

    case System.find_executable("wrangler") do
      nil ->
        {:error, "wrangler not found — install with: npm i -g wrangler", %{}}

      wrangler ->
        account = config["PUBLISH_CF_ACCOUNT"] || System.get_env("CLOUDFLARE_ACCOUNT_ID")
        env = if account, do: [{"CLOUDFLARE_ACCOUNT_ID", account}], else: []

        args = "#{wrangler} pages deploy #{dist} --project-name #{project} --commit-dirty=true"

        case System.cmd("sh", ["-c", args], stderr_to_stdout: true, env: env) do
          {out, 0} ->
            url = domain || extract_cf_url(out) || "https://#{project}.pages.dev"
            {:ok, "deployed → #{url}\n#{String.trim(out)}", %{url: url}}

          {out, code} ->
            {:error, "wrangler deploy failed (exit #{code}):\n#{String.trim(out)}", %{}}
        end
    end
  end

  defp ship_gh_pages(dist, config) do
    repo = config["PUBLISH_PROJECT"]
    domain = config["PUBLISH_DOMAIN"]
    tmp = System.tmp_dir!() |> Path.join("wb_site_ghpages_#{:erlang.unique_integer([:positive])}")

    with {_, 0} <- System.cmd("git", ["clone", "--depth=1", "--branch=gh-pages",
                                       "https://github.com/#{repo}.git", tmp], stderr_to_stdout: true),
         :ok <- copy_dir(dist, tmp),
         {_, 0} <- System.cmd("git", ["-C", tmp, "add", "."], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", tmp, "commit", "-m", "wb publish site: update docs"],
                               stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", tmp, "push"], stderr_to_stdout: true) do
      File.rm_rf!(tmp)
      url = if domain, do: "https://#{domain}", else: "https://#{String.replace(repo, "/", ".github.io/")}"
      {:ok, "deployed → #{url}", %{url: url}}
    else
      {out, code} when is_integer(code) ->
        File.rm_rf!(tmp)
        {:error, "gh-pages deploy failed (exit #{code}):\n#{String.trim(to_string(out))}", %{}}

      {:error, e} ->
        File.rm_rf!(tmp)
        {:error, "gh-pages deploy failed: #{inspect(e)}", %{}}
    end
  end

  defp copy_dir(src, dest) do
    src
    |> File.ls!()
    |> Enum.each(fn name ->
      File.cp_r!(Path.join(src, name), Path.join(dest, name))
    end)

    :ok
  end

  defp extract_cf_url(output) do
    case Regex.run(~r/https:\/\/[^\s]+\.pages\.dev/, output) do
      [url] -> url
      _ -> nil
    end
  end

  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  @doc "Summary line for CLI output."
  def summary(%{sections: sections}) do
    count = sections |> Enum.flat_map(& &1.pages) |> length()
    "#{count} pages across #{length(sections)} sections"
  end
end
