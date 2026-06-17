defmodule Workbooks.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers for `Workbooks.Web` that don't need request/response
  plumbing: workdir confinement, request-param sanitizers, the AI-over-files
  answer synthesis, the /api/browse dispatch, JSON-safing, did:web host
  resolution, and static toolkit/repo file serving.

  `conn`-taking helpers here use only `Plug.Conn` (imported) — the router still
  owns the route bodies; these are the bodies' factored-out internals.
  """
  import Plug.Conn

  # The agent keys an org may provision for its members (wb-xiei.2). Allowlisted so
  # GET /api/org-secrets can never exfiltrate arbitrary tenant vars and POST can't
  # write outside this set.
  def org_secret_keys, do: ~w(OPENROUTER_API_KEY GEMINI_API_KEY)

  # Serve a file from the runtime root, read FRESH (so dashboard/ledger edits are
  # live). Tries cwd then the source-relative path so it works under `mix`
  # regardless of where the runtime was launched.
  def serve_repo_file(conn, name, ctype) do
    body =
      [Path.join(File.cwd!(), name), Path.expand(Path.join([__DIR__, "..", "..", name]))]
      |> Enum.find_value(fn p -> match?({:ok, _}, File.read(p)) && File.read!(p) end)

    if body do
      conn |> put_resp_content_type(ctype) |> send_resp(200, body)
    else
      send_resp(conn, 404, ~s({"error":"#{name} not found"}))
    end
  end

  # Workdir confinement (wb-g1yo.4b): the DESKTOP (trusted, single-tenant) may
  # name its own local workbook path; a CLOUD/shared caller MUST NOT.
  def effective_workdir(tenant, run_id, requested),
    do: confined_workdir(Workbooks.Desktop.enabled?(), tenant, run_id, requested)

  # Normalize a harness-session :commands cap from request params: a list of command names scopes the grant
  # to those; anything else (incl. absent) => :all (the broker still default-denies past the registry).
  def commands_param(list) when is_list(list), do: Enum.map(list, &to_string/1)
  def commands_param(_), do: :all

  # The caller-supplied harness session sub-id, reduced to one flat traversal-proof
  # segment (same charset filter as a path segment). A blank/absent value gets a
  # fresh host-generated id. This keeps the FS workdir confined AND the namespaced
  # Registry/ETS key a clean tenant-scoped token.
  def harness_sub(requested) do
    case requested |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_") do
      "" -> "h-#{System.unique_integer([:positive])}"
      s -> s
    end
  end

  @doc false
  # Pure (testable): desktop-trusted callers keep their requested local path; any
  # other (cloud/shared) caller is confined to a per-tenant scratch root — no
  # arbitrary host path, no cross-tenant FS reach.
  def confined_workdir(desktop?, tenant, run_id, requested) do
    if desktop? and is_binary(requested) and requested != "" do
      requested
    else
      base = System.get_env("WB_DATA") || System.tmp_dir!()
      # Strip dots too (not just separators) so a tenant like "../../etc" can't
      # smuggle ".." into the path. BOTH segments are sanitized: `run_id` is
      # caller-derived on the harness route (= "harness-" <> caller session), so
      # an unsanitized `run_id` was a path-traversal escape (e.g.
      # session "x/../../tenantB" -> /data/wb-runs/<t>/harness-x/../../tenantB).
      # Sanitizing here confines EVERY caller of confined_workdir, not just the
      # one route — defense-in-depth so a future caller can't reintroduce it.
      safe_tenant = safe_segment(tenant, "anon")
      safe_run_id = safe_segment(run_id, "run")
      Path.join([base, "wb-runs", safe_tenant, safe_run_id])
    end
  end

  # A single, flat, traversal-proof path segment: collapse every char outside
  # [A-Za-z0-9_-] (separators, dots, NUL, whitespace) to "_", so neither a
  # tenant nor a caller session id can smuggle "/" or ".." into the FS path.
  defp safe_segment(value, fallback) do
    case (value || fallback) |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_") do
      "" -> fallback
      s -> s
    end
  end

  def wb_exec(argv, tenant) do
    Workbooks.CLI.call(argv, tenant)
  rescue
    e -> "error: #{Exception.message(e)}"
  end

  # A scope is an opaque workbook id: letters/digits/_/- only, no `.`, no separators
  # or traversal (`/`, `..`). Confinement floor (wb-g1yo.10) — never a host path.
  def valid_scope(s) when is_binary(s) and s != "" do
    if s =~ ~r/\A[A-Za-z0-9_-]+\z/, do: :ok, else: :error
  end

  def valid_scope(_), do: :error

  # Synthesize a grounded, cited answer from library hits (AI-over-files, wb-ndlz).
  # Empty hits → an HONEST "couldn't find it" (no fabricated files/facts), no LLM call.
  def library_ask(query, []) do
    %{
      answer:
        "I couldn't find anything in your files about \"#{query}\". Nothing in your library matched — " <>
          "I won't make something up. Try different words, or add the relevant workbook.",
      sources: [],
      related: []
    }
  end

  def library_ask(query, hits) do
    sources =
      Enum.map(hits, fn h ->
        %{
          title: Map.get(h, :headline) || Map.get(h, :path),
          path: Map.get(h, :path),
          snippet: h |> Map.get(:text, "") |> to_string() |> String.slice(0, 200)
        }
      end)

    context =
      hits
      |> Enum.map(fn h -> "- #{Map.get(h, :path)}: #{h |> Map.get(:text, "") |> to_string() |> String.slice(0, 400)}" end)
      |> Enum.join("\n")

    system =
      "You answer the user's question using ONLY the provided excerpts from THEIR OWN files. " <>
        "Cite which file each point comes from (by its path). If the excerpts don't cover the question, " <>
        "say so plainly — NEVER invent files, paths, or facts not present in the excerpts. Be concise."

    user = "Question: #{query}\n\nExcerpts from the user's files:\n#{context}"

    answer =
      case Workbooks.Llm.complete([%{role: "system", content: system}, %{role: "user", content: user}]) do
        {:ok, %{content: t}} when is_binary(t) and t != "" -> t
        _ -> "(no answer — the model didn't respond)"
      end

    %{answer: answer, sources: sources, related: []}
  end

  # Dispatch a /api/browse request to the Browse capability.
  def browse(%{"mode" => "search", "query" => q} = p) do
    case Workbooks.Browse.search(q, limit: Map.get(p, "limit", 8)) do
      {:ok, results} -> %{mode: "search", query: q, results: results}
      {:error, reason} -> %{mode: "search", error: inspect(reason)}
    end
  end

  def browse(%{"mode" => "crawl", "url" => url} = p) do
    {:ok, pages} = Workbooks.Browse.crawl(url, max_pages: Map.get(p, "max_pages", 10))
    render_pages(pages, Map.get(p, "as", "json"))
  end

  def browse(%{"url" => url} = p) do
    case Workbooks.Browse.fetch(url) do
      {:ok, page} -> render_pages([page], Map.get(p, "as", "json"))
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp render_pages(pages, "org"),
    do: %{count: length(pages), org: Workbooks.Browse.Crawl.to_org(pages)}

  defp render_pages(pages, _),
    do: %{count: length(pages), pages: Enum.map(pages, &Map.take(&1, [:url, :title, :description, :headings]))}

  # Serve a file from <toolkits_root>/<toolkit>/<rel>, path-contained (no escape).
  def serve_toolkit_file(conn, toolkit, rel) do
    base = Path.expand(Path.join(Workbooks.WorkKits.default_root(), toolkit))
    path = Path.expand(Path.join(base, rel))

    cond do
      path != base and not String.starts_with?(path, base <> "/") ->
        send_resp(conn, 403, "forbidden")

      not File.regular?(path) ->
        send_resp(conn, 404, "not found")

      true ->
        conn |> put_resp_content_type(ctk_ctype(path)) |> send_resp(200, File.read!(path))
    end
  end

  defp ctk_ctype(path) do
    case Path.extname(path) do
      ".html" -> "text/html"
      ".js" -> "text/javascript"
      ".css" -> "text/css"
      ".org" -> "text/plain"
      ".json" -> "application/json"
      ".svg" -> "image/svg+xml"
      _ -> "application/octet-stream"
    end
  end

  # Make any term JSON-encodable: tuples → inspected strings, recursing through
  # maps/lists. Run/checkout results legitimately carry error tuples (bd wb-ica).
  def json_safe(%_{} = struct), do: struct
  def json_safe(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, json_safe(v)} end)
  def json_safe(l) when is_list(l), do: Enum.map(l, &json_safe/1)
  def json_safe(t) when is_tuple(t), do: inspect(t)
  def json_safe(other), do: other

  # The public authority for did:web — prefer the proxy's forwarded host (fly
  # terminates TLS upstream) so the DID id matches the URL clients actually used.
  def host_authority(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-host") do
      [h | _] when is_binary(h) and h != "" -> h
      _ -> conn.host
    end
  end
end
