defmodule Workbooks.Publish do
  @moduledoc """
  The publish-kit — render a Workbook (.html) to a self-contained HTML page and
  ship it to a provider. One workbook = one URL.

    * `cloudflare-pages` — wrangler pages deploy (already used by the lander)
    * `gh-pages`         — git push to the gh-pages branch of a repo
    * `self-hosted`      — POST the HTML blob to a running runtime's /publish API

  THE FLOW (declarative — mirrors deploy-kit):
    work publish init                scaffold ./publish.html
    work publish validate            coherence-check it (no render, no deploy)
    work publish apply <file.html>   render + ship → prints the live URL
  (workbook defaults to ./workbook.html; config defaults to ./publish.html)

  Rendering reuses `PublicWeb.static_page/2`: a workbook IS HTML, so a complete
  document is served verbatim and a fragment is wrapped in the doc shell. No
  server required at publish time.
  """
  alias Workbooks.Publish.Config

  @default_config "publish.html"
  @default_workbook "workbook.html"

  @template """
  <!-- Publish configuration — one declarative description of where this workbook lives.
       Edit, then:  work publish validate  →  work publish apply <workbook.html>
       Secrets (API keys, tokens, account IDs) do NOT go here. Use env vars
       (CLOUDFLARE_ACCOUNT_ID, etc.). -->
  <work-publish
    publish-target="cloudflare-pages"
    publish-project="<your-pages-project-name>"
    publish-domain="<your-domain-or-pages.dev-url>"
    publish-title="<page title>"></work-publish>
  """

  @doc "Scaffold a publish.html. Starting point."
  def init(opts \\ []) do
    file = Keyword.get(opts, :file, @default_config)
    force? = Keyword.get(opts, :force, false)

    cond do
      File.exists?(file) and not force? ->
        err("#{file} already exists — edit it, or `work publish init --force` to replace it", %{file: file})

      true ->
        File.write!(file, @template)
        ok("wrote #{file} — edit it, then `work publish validate` → `work publish apply <workbook.html>`", %{file: file})
    end
  end

  @doc "Coherence-check a publish.html without rendering or deploying."
  def validate(config_file) do
    with :ok <- exists(config_file),
         {:ok, p} <- Config.parse(config_file) do
      case Config.validate(p) do
        :ok -> ok("valid — #{Config.summary(p)}", %{valid: true})
        {:error, issues} ->
          err("invalid publish config:\n  - " <> Enum.join(issues, "\n  - "), %{valid: false, issues: issues})
      end
    else
      {:error, msg} -> err(msg, %{})
    end
  end

  @doc """
  Render `workbook_file` → HTML, then ship to the configured provider.
  `config_file` defaults to ./publish.html; `workbook_file` defaults to
  ./workbook.html.
  """
  def apply(workbook_file, config_file) do
    with :ok <- exists(config_file),
         :ok <- exists(workbook_file),
         {:ok, p} <- Config.parse(config_file),
         :ok <- coherent(p),
         {:ok, out_path} <- render(workbook_file, p) do
      ship(out_path, p)
    else
      {:error, issues} when is_list(issues) ->
        err("invalid publish config:\n  - " <> Enum.join(issues, "\n  - "), %{issues: issues})
      {:error, msg} ->
        err(msg, %{})
    end
  end

  # Render the workbook HTML → a self-contained page. Reuses PublicWeb.static_page/2
  # (a complete document serves verbatim; a fragment gets the doc shell) — the same
  # render path the runtime's public plane uses.
  defp render(workbook_file, p) do
    src = File.read!(workbook_file)
    html = Workbooks.PublicWeb.static_page(Config.title(p), src)
    out = p["PUBLISH_OUTPUT"] || ".publish_out/index.html"
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, html)
    {:ok, out}
  end

  # Dispatch to the provider.
  defp ship(html_path, p) do
    case Config.target(p) do
      "cloudflare-pages" -> ship_cloudflare(html_path, p)
      "gh-pages" -> ship_gh_pages(html_path, p)
      "self-hosted" -> ship_self_hosted(html_path, p)
      "desktop-app" -> ship_desktop_app(html_path, p)
      other -> err("unknown PUBLISH_TARGET: #{other}", %{})
    end
  end

  # Desktop-app — scaffold a runtime-connected workbook app (RCP-wired frontend +
  # connector + tauri config). `tauri build` over the emitted dir produces the .app.
  defp ship_desktop_app(html_path, p) do
    case Workbooks.Publish.DesktopApp.scaffold(html_path, p) do
      {:ok, %{dir: dir, files: files, url: url}} ->
        target = if url == "", do: "local runtime (discovery at boot)", else: url
        ok("scaffolded desktop-app → #{dir}\n  files: #{Enum.join(files, ", ")}\n  runtime: #{target}\n  next: tauri build (see README.txt)",
          %{target: "desktop-app", dir: dir, files: files, runtime: url})

      {:error, reason} ->
        err("desktop-app scaffold failed: #{reason}", %{target: "desktop-app"})
    end
  end

  # Cloudflare Pages — wrangler pages deploy <dir> --project-name <project>.
  # Wrangler is already a dep of the lander; must be on PATH.
  defp ship_cloudflare(html_path, p) do
    dir = Path.dirname(html_path)
    project = p["PUBLISH_PROJECT"]
    domain = p["PUBLISH_DOMAIN"]

    case System.find_executable("wrangler") do
      nil ->
        err("wrangler not found on PATH — install with: npm i -g wrangler", %{target: "cloudflare-pages"})

      wrangler ->
        account = p["PUBLISH_CF_ACCOUNT"] || System.get_env("CLOUDFLARE_ACCOUNT_ID")
        env = if account, do: [{"CLOUDFLARE_ACCOUNT_ID", account}], else: []
        args = [wrangler, "pages", "deploy", dir, "--project-name", project]
        case System.cmd("sh", ["-c", Enum.join(args, " ")], stderr_to_stdout: true, env: env) do
          {out, 0} ->
            url = domain || extract_cf_url(out) || "https://#{project}.pages.dev"
            ok("deployed → #{url}\n#{String.trim(out)}", %{url: url, target: "cloudflare-pages"})
          {out, code} ->
            err("wrangler deploy failed (exit #{code}):\n#{String.trim(out)}", %{target: "cloudflare-pages"})
        end
    end
  end

  # GitHub Pages — push the rendered HTML to the gh-pages branch of the repo.
  defp ship_gh_pages(html_path, p) do
    repo = p["PUBLISH_PROJECT"]
    domain = p["PUBLISH_DOMAIN"]
    tmp = System.tmp_dir!() |> Path.join("wb_ghpages_#{:erlang.unique_integer([:positive])}")

    with {_, 0} <- System.cmd("git", ["clone", "--depth=1", "--branch=gh-pages",
                                       "https://github.com/#{repo}.git", tmp], stderr_to_stdout: true),
         :ok <- File.cp(html_path, Path.join(tmp, "index.html")),
         {_, 0} <- System.cmd("git", ["-C", tmp, "add", "index.html"], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", tmp, "commit", "-m", "work publish: update workbook"],
                               stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", tmp, "push"], stderr_to_stdout: true) do
      url = if domain, do: "https://#{domain}", else: "https://#{String.replace(repo, "/", ".github.io/", global: false)}"
      File.rm_rf!(tmp)
      ok("deployed → #{url}", %{url: url, target: "gh-pages"})
    else
      {out, code} when is_integer(code) ->
        File.rm_rf!(tmp)
        err("gh-pages deploy failed (exit #{code}):\n#{String.trim(to_string(out))}", %{target: "gh-pages"})
      {:error, e} ->
        File.rm_rf!(tmp)
        err("gh-pages deploy failed: #{inspect(e)}", %{target: "gh-pages"})
    end
  end

  # Self-hosted — POST the HTML to the runtime's /publish endpoint.
  defp ship_self_hosted(html_path, p) do
    base_url = String.trim_trailing(p["PUBLISH_URL"], "/")
    html = File.read!(html_path)

    :inets.start()
    :ssl.start()

    body = Jason.encode!(%{"html" => html, "id" => (p["PUBLISH_PROJECT"] || "workbook")})
    url = String.to_charlist("#{base_url}/api/publish")
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [timeout: 15_000], []) do
      {:ok, {{_, 200, _}, _, resp}} ->
        result = Jason.decode!(resp)
        live_url = result["url"] || base_url
        ok("deployed → #{live_url}", %{url: live_url, target: "self-hosted"})
      {:ok, {{_, status, _}, _, resp}} ->
        err("self-hosted publish failed (HTTP #{status}): #{resp}", %{target: "self-hosted"})
      {:error, reason} ->
        err("self-hosted publish failed: #{inspect(reason)}", %{target: "self-hosted"})
    end
  end

  # Pull the deployment URL wrangler prints on success.
  defp extract_cf_url(output) do
    case Regex.run(~r/https:\/\/[^\s]+\.pages\.dev/, output) do
      [url] -> url
      _ -> nil
    end
  end

  @doc "Render a tagged result for the CLI."
  def render_result({tag, msg, data}, json?) do
    if json?,
      do: Jason.encode!(Map.merge(%{ok: tag == :ok, message: msg}, data)),
      else: if(tag == :ok, do: msg, else: "publish error: #{msg}")
  end

  @doc "Did a verb fail?"
  def failed?({:error, _, _}), do: true
  def failed?(_), do: false

  # ---- helpers ---------------------------------------------------------------
  defp ok(msg, data), do: {:ok, msg, data}
  defp err(msg, data), do: {:error, msg, data}

  defp exists(file) do
    if File.exists?(file), do: :ok, else: {:error, "no #{file} found"}
  end

  defp coherent(p) do
    case Config.validate(p), do: (:ok -> :ok; {:error, issues} -> {:error, issues})
  end

  @doc "Default config + workbook paths."
  def default_config, do: @default_config
  def default_workbook, do: @default_workbook
end
