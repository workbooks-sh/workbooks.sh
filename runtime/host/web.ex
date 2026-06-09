defmodule Workbooks.Web do
  @moduledoc """
  The HTTP/WS surface. Authenticate, then create/resume Instances and run OQL.
  Bandit serves this Plug router (opt-in via WB_WEB=1).
  """
  use Plug.Router

  plug(Workbooks.Auth)
  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # RCP handshake (RUNTIME-CONNECT-PROTOCOL.org §1): unauthenticated capabilities
  # doc so any client learns the required auth rung + feature surface before
  # presenting a credential. Public (see Workbooks.Auth @public).
  get "/.well-known/workbooks-runtime" do
    json = Jason.encode!(Workbooks.Web.Capabilities.doc())
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # Sealed-bundle key release (wb-v3w, "rzip"). A `.wbundle` seals gated entries as
  # AES-256-GCM ciphertext whose content key is escrowed here, never in the bundle.
  # This is the runtime dead-man switch: the key is released ONLY when
  # Workbooks.Access.enforce passes for the caller's identity. A sealed entry is
  # gated by definition, so the posture is :gated_data with a :data demand — a real
  # authenticated identity is required. FAIL CLOSED: on deny or a missing key we
  # return the SAME error envelope an unauthorized RCP call already uses; the key
  # (and therefore the plaintext) never leaks.
  post "/rcp/key/:key_id" do
    key_id = conn.params["key_id"]
    identity = conn.assigns[:identity]

    case Workbooks.Access.enforce(:gated_data, :data, identity) do
      :allow ->
        case Workbooks.Bundle.Escrow.get(key_id) do
          {:ok, key} ->
            # Escrow fallback (no did supplied): hand back the raw content key,
            # base64'd, for the client to AES-256-GCM decrypt the sealed entry.
            body = Jason.encode!(%{key_id: key_id, algo: "aes-256-gcm", key: Base.encode64(key)})
            conn |> put_resp_content_type("application/json") |> send_resp(200, body)

          {:error, :no_such_key} ->
            # Don't disclose whether the key exists to an authed-but-wrong caller in
            # a way that differs from deny — but a genuine 404 is fine post-auth.
            Workbooks.Web.Error.render(conn, :not_found, "no such key")
        end

      {:deny, _reason} ->
        Workbooks.Web.Error.render(conn, :unauthorized, "unauthorized")
    end
  end

  # Parse Org through the OQL kernel.
  post "/oql/parse" do
    {:ok, body, conn} = read_body(conn)
    json = Jason.encode!(Workbooks.OQL.parse_headlines(body))
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # Run a workflow declared in Org — the runtime parses the :workflow: DAG and
  # executes it (topological waves; agent + WASM components; recursive).
  #   {"org": "...", "input": "..."}  → run records
  #   ?plan=1                         → the schedule/plan only (no execution)
  post "/api/workflow" do
    {:ok, body, conn} = read_body(conn)
    %{"org" => org} = params = Jason.decode!(body)

    try do
      out =
        if conn.params["plan"] == "1",
          do: Workbooks.Workflow.list(org),
          else: Workbooks.Workflow.run(org, Map.get(params, "input", ""))

      # Run results can carry error TUPLES ({:error, {:input_too_large, …}});
      # encode-safe them instead of 500ing on Jason.Encoder (bd wb-ica).
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(json_safe(out)))
    rescue
      e -> conn |> put_resp_content_type("application/json") |> send_resp(500, Jason.encode!(%{error: Exception.message(e)}))
    end
  end

  # Run a NATIVE org TODO outline as a workflow (the implicit interpreter — no
  # custom tags; the outline IS the state machine). Async: spawns the run, poll
  # at /api/brand-book/<slug> for the per-task states. {"org": "..."}.
  post "/api/workflow/todo" do
    {:ok, body, conn} = read_body(conn)
    %{"org" => org} = Jason.decode!(body)
    slug = "wf-#{System.unique_integer([:positive])}"
    workdir = "/tmp/bb/#{slug}"
    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, stage: "running"}))

    spawn(fn ->
      try do
        res = Workbooks.Workflow.Todo.run(org, workdir: workdir)
        File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, stage: "done", tasks: res.tasks}))
      rescue
        e -> File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, stage: "error", error: Exception.message(e)}))
      end
    end)

    conn |> put_resp_content_type("application/json") |> send_resp(202, Jason.encode!(%{slug: slug, status: "running"}))
  end

  # List registered Instances for the tenant.
  get "/instances" do
    json = Jason.encode!(Workbooks.ControlPlane.list())
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # Deploy a Workbook: store its Org source under :id.
  put "/w/:id" do
    {:ok, org, conn} = read_body(conn)
    Workbooks.deploy(conn.params["id"], org, conn.assigns.tenant)
    send_resp(conn, 201, "stored")
  end

  # Serve a Workbook as a webpage — the runtime renders the stored Org (or a
  # built-in sample if none is deployed under :id) and serves the UI.
  get "/w/:id" do
    id = conn.params["id"]
    org = Workbooks.ControlPlane.get_workbook(id) || sample_workbook()
    page = workbook_page(id, Workbooks.OQL.render(org))
    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  # The Workbook's backend: the served page calls home to its own runtime.
  post "/w/:id/call" do
    {:ok, body, conn} = read_body(conn)
    %{"fn" => fun, "org" => org} = Jason.decode!(body)

    result =
      case fun do
        "parse" -> Workbooks.OQL.parse_headlines(org)
        "tangle" -> Workbooks.OQL.tangle_plan(org)
        "validate" -> Workbooks.OQL.validate(org)
        _ -> %{"error" => "unknown fn"}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # Live bridge: upgrade to a WebSocket connected to this Workbook.
  get "/w/:id/ws" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.Socket, %{id: conn.params["id"]}, timeout: 60_000)
    |> halt()
  end

  # Start a long-horizon agent run (returns immediately; poll /api/run/:id).
  # The same endpoint runs locally and in the deployed engine (Fly).
  post "/api/run" do
    {:ok, body, conn} = read_body(conn)
    %{"system" => system, "task" => task} = params = Jason.decode!(body)
    id = "run-#{System.unique_integer([:positive])}"

    opts =
      [tenant: conn.assigns.tenant, max_steps: params["max_steps"] || 40]
      |> then(&if params["model"], do: [{:model, params["model"]} | &1], else: &1)
      # exec grants the real-CLI `run` tool (sh -c, toolkit CLIs on PATH). Forwarded
      # from the request so a caller can run a trusted agent; gate WHO can set it
      # per deployment (single-tenant/desktop is the trusted local case).
      |> then(&if params["exec"] == true, do: [{:exec, true} | &1], else: &1)

    {:ok, _} = Workbooks.AgentSession.start(id, system, task, opts)
    json = Jason.encode!(%{id: id, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Live agent telemetry — each tool step streamed as it happens (brandnana-style).
  get "/api/run/:id/stream" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.AgentStream, %{id: conn.params["id"]}, timeout: 600_000)
    |> halt()
  end

  # Poll an agent run's status + result + observable events.org.
  get "/api/run/:id" do
    reply =
      case Workbooks.AgentSession.status(conn.params["id"]) do
        :not_found -> %{error: "no such run"}
        s -> s
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(reply))
  end

  # ── CTK human-in-the-loop (toolkits/ctk) ──────────────────────────────────
  # The CTK shell POSTs a `ctk.commit` event here when a human approves a review;
  # we deliver it into the run's session. The run id comes from the connector URL
  # the runtime baked when it served CTK (…/api/ctk/commit?run=<id>) or the event
  # body. The agent (bash-only) then polls GET /api/ctk/review/:id to receive it
  # and commit the approved snapshot. See toolkits/ctk/skills/commit-connector.org.
  post "/api/ctk/commit" do
    {:ok, body, conn} = read_body(conn)
    conn = fetch_query_params(conn)
    event = Jason.decode!(body)
    run_id = conn.query_params["run"] || event["run"]

    {code, reply} =
      cond do
        is_nil(run_id) ->
          {400, %{error: "missing run id (pass ?run=<id> or event.run)"}}

        true ->
          case Workbooks.AgentSession.put_review(run_id, event) do
            :ok -> {202, %{ok: true, run: run_id}}
            :not_found -> {404, %{error: "no such run", run: run_id}}
          end
      end

    conn |> put_resp_content_type("application/json") |> send_resp(code, Jason.encode!(reply))
  end

  # The agent polls this to receive a pending review (204 when none yet).
  get "/api/ctk/review/:id" do
    case Workbooks.AgentSession.take_review(conn.params["id"]) do
      :not_found ->
        conn |> put_resp_content_type("application/json") |> send_resp(404, Jason.encode!(%{error: "no such run"}))

      nil ->
        send_resp(conn, 204, "")

      review ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(review))
    end
  end

  # Serve the CTK render toolkit (shell + stories) from the toolkits root, so the
  # runtime — not a separate static server — hosts the human-in-the-loop canvas.
  # The shell POSTs back to /api/ctk/commit on this same origin.
  get "/ctk" do
    serve_toolkit_file(conn, "ctk", "ctk.html")
  end

  get "/ctk/*glob" do
    serve_toolkit_file(conn, "ctk", Enum.join(conn.path_params["glob"], "/"))
  end

  # Run the full brandnana brand book for a domain (harvest → strategist →
  # designer), the real pipeline ported onto the clean-room agent loop. Long-
  # horizon: spawns + returns immediately; poll /api/brand-book/:slug.
  post "/api/run-brand-book" do
    {:ok, body, conn} = read_body(conn)
    %{"domain" => domain} = Jason.decode!(body)
    slug = String.replace(domain, ~r/[^a-z0-9]/i, "-")
    workdir = "/tmp/bb/#{slug}"
    # FRESH per run: a reused workdir keeps the prior run's catalog SQLite, which
    # makes the re-crawl 409 ("already exists") → 0 products → a thin substrate
    # the strategist can't ground on. Each brand-book run starts from a clean dir.
    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    # Capture any crash so a dead spawn is diagnosable (else status freezes silently).
    spawn(fn ->
      try do
        Workbooks.BrandBook.run(domain, workdir: workdir)
      rescue
        e -> File.write(Path.join(workdir, "_error.json"),
               Jason.encode!(%{error: Exception.message(e), kind: inspect(e.__struct__), trace: Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 1200)}))
      end
    end)
    json = Jason.encode!(%{slug: slug, domain: domain, workdir: workdir, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Free-form brandnana agent: take an OPEN request (a brand, several brands, an
  # industry, an ad/trends question) and let the Brandnana agent drive the
  # brandnana toolkit freely to deliver a queryable presentation workbook. No
  # fixed pipeline — the agent decides the path (and may spawn sub-agents).
  post "/api/brandnana-ask" do
    {:ok, body, conn} = read_body(conn)
    %{"request" => request} = Jason.decode!(body)
    slug = "ask-" <> (request |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.slice(0, 28)) <> "-#{System.unique_integer([:positive])}"
    workdir = "/tmp/bb/#{slug}"
    File.rm_rf!(workdir)
    File.mkdir_p!(workdir)
    File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, request: request, stage: "running"}))

    spawn(fn ->
      def_path = "#{System.get_env("WB_PROFILE_DIR") || "/opt/profile"}/agents/brandnana.org"
      on_step = fn ev ->
        File.write(Path.join(workdir, "_trace.jsonl"), Jason.encode!(%{step: ev.step, tool: ev.tool, out: String.slice(ev.output || "", 0, 140)}) <> "\n", [:append])
      end

      try do
        result = Workbooks.AgentDef.run(File.read!(def_path), request, exec: true, workdir: workdir, max_steps: 250, on_step: on_step)

        pub =
          case File.read(Path.join(workdir, "published-url")) do
            {:ok, u} -> String.trim(u)
            _ -> nil
          end

        File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, request: request, stage: "done", published: pub, result: String.slice(result.result || "", 0, 400)}))
      rescue
        e -> File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, request: request, stage: "error", error: Exception.message(e)}))
      end
    end)

    json = Jason.encode!(%{slug: slug, request: request, workdir: workdir, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Poll a brand-book run — the stage + published deck URL (BrandBook writes
  # _status.json into the workdir as each stage starts/finishes).
  get "/api/brand-book/:slug" do
    path = "/tmp/bb/#{conn.params["slug"]}/_status.json"
    body = case File.read(path) do
      {:ok, j} -> j
      _ -> Jason.encode!(%{error: "no such run", slug: conn.params["slug"]})
    end
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # Telemetry feedback loop (CLI reads this): task states + tool-call count +
  # total time + errors (bash exit codes / tool failures) for a run.
  get "/api/telemetry/:slug" do
    summary = Workbooks.Workflow.Telemetry.summary("/tmp/bb/#{conn.params["slug"]}")
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(summary))
  end

  # Library (Phase 3) — the tenant's access graph: workspaces + their members.
  get "/api/library/:tenant" do
    wss = Workbooks.Library.workspaces(conn.params["tenant"])
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{workspaces: wss}))
  end

  # Cross-workbook OQL query-through across a Library's members. {"sql": "..."}
  post "/api/library/:tenant/query" do
    {:ok, body, conn} = read_body(conn)
    sql = Jason.decode!(body)["sql"] || ""
    result = Workbooks.Library.query(conn.params["tenant"], sql)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # ── RCP engine verbs for the `wb` CLI (token → tenant; see cli/TAXONOMY.md) ──
  # These mirror the escript's local Library.* calls, but token-authed so the thin
  # Rust CLI can drive a running engine. Tenant comes from the credential, not a path.

  # `wb build` — compile a workspace's components → WASM.
  post "/rcp/build" do
    t = conn.assigns.tenant
    slug = conn.params["src"] || conn.params["slug"] || "."
    result = try do
      Workbooks.Library.build(t, slug)
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # `wb checkout` / `wb checkin` — borrow a library member / pack it back.
  # BYTES over RCP: the CLI may be on a different machine than the engine (the
  # engine usually runs in a container), so working trees can't be engine-side
  # paths. checkout zips the member's tree back to the caller; checkin accepts a
  # zip and writes it back into the library. The zip is the same :zip format as
  # Workbooks.Bundle.
  post "/rcp/library/checkout" do
    t = conn.assigns.tenant
    result = try do
      tmp = Path.join(System.tmp_dir!(), "wb-co-#{System.unique_integer([:positive])}")
      case Workbooks.Library.checkout(t, conn.params["member"], tmp) do
        %{error: e} -> %{error: e}
        ok ->
          parts =
            Path.wildcard(Path.join(tmp, "**"))
            |> Enum.filter(&File.regular?/1)
            |> Map.new(fn p -> {Path.relative_to(p, tmp), File.read!(p)} end)
          File.rm_rf!(tmp)
          %{ok: true, scope: ok[:scope], b64: Base.encode64(Workbooks.Bundle.pack(parts))}
      end
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(json_safe(result)))
  end

  post "/rcp/library/checkin" do
    t = conn.assigns.tenant
    {:ok, body, conn} = read_body(conn, length: 100_000_000)
    result = try do
      %{"b64" => b64} = Jason.decode!(body)
      tmp = Path.join(System.tmp_dir!(), "wb-ci-#{System.unique_integer([:positive])}")
      for {name, content} <- Workbooks.Bundle.unpack(Base.decode64!(b64)) do
        dest = Path.join(tmp, name)
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, content)
      end
      out = Workbooks.Library.checkin(t, conn.params["member"], tmp) |> Map.drop([:member])
      File.rm_rf!(tmp)
      out
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(json_safe(result)))
  end

  # `wb store` / `wb store --list` — archive a workspace / list stored keys.
  get "/rcp/store" do
    t = conn.assigns.tenant
    result = try do %{stored: Workbooks.Library.stored(t)} rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  post "/rcp/store" do
    t = conn.assigns.tenant
    result = try do
      case Workbooks.Library.store(t, conn.params["slug"] || ".", build: conn.params["build"] == "1") do
        {:ok, key} -> %{ok: true, key: key}
        {:error, e} -> %{ok: false, error: to_string(e)}
        other -> %{ok: true, result: inspect(other)}
      end
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # ── `wb toolkit` — the agent-extensibility surface over RCP ─────────────────
  # Mirrors the escript verbs (Toolkits.*_text) so a REMOTE/containerized engine
  # is reachable from the thin CLI. Text in/out — these are help-surface +
  # build/run verbs, not data APIs. Task execution stays server-side gated
  # (WB_TOOLKIT_EXEC=1 default-deny + Sandbox, see Workbooks.Toolkits).

  get "/rcp/toolkit" do
    send_resp(conn, 200, Workbooks.Toolkits.list_text())
  end

  get "/rcp/toolkit/show" do
    out =
      case conn.params["skill"] do
        s when s in [nil, ""] -> Workbooks.Toolkits.show_text(conn.params["id"])
        skill -> Workbooks.Toolkits.show_skill_text(conn.params["id"], skill)
      end

    send_resp(conn, 200, out)
  end

  get "/rcp/toolkit/search" do
    send_resp(conn, 200, Workbooks.Toolkits.search_text(conn.params["q"] || ""))
  end

  post "/rcp/toolkit/verify" do
    send_resp(conn, 200, Workbooks.Toolkits.verify_text(conn.params["id"]))
  end

  # Run a toolkit's eval suite server-side (NIFs + LLM available here; bash/agent
  # execution gated by the runtime's WB_TOOLKIT_EXEC). The thin CLI hits this.
  post "/rcp/toolkit/eval" do
    conn = fetch_query_params(conn)
    send_resp(conn, 200, Workbooks.Toolkits.eval_text(conn.query_params["id"]))
  end

  post "/rcp/toolkit/build" do
    out =
      case conn.params["which"] do
        w when w in [nil, ""] -> Workbooks.Toolkits.build_text(conn.params["id"])
        which -> Workbooks.Toolkits.build_text(conn.params["id"], which, Workbooks.Toolkits.default_root())
      end

    send_resp(conn, 200, out)
  end

  post "/rcp/toolkit/sign" do
    send_resp(conn, 200, Workbooks.Toolkits.sign_text(conn.params["id"], conn.assigns.tenant))
  end

  # Run a registered KERNEL (bytes → bytes) over RCP — the seam that makes
  # kernel-shape toolkits reachable from ANY client (desktop renderer, CLI,
  # scripts) without embedding wasmtime themselves. One-shot open/call/close;
  # hot loops belong engine-side (Workbooks.Fabric), not over HTTP.
  post "/rcp/kernel/run" do
    {:ok, body, conn} = read_body(conn, length: 100_000_000)

    result =
      try do
        %{"b64" => b64} = Jason.decode!(body)
        input = Base.decode64!(b64)
        name = conn.params["name"]

        case Workbooks.KernelRegistry.path(name) do
          nil ->
            %{error: "no such kernel: #{name}"}

          path ->
            case Workbooks.Kernel.run_batch(File.read!(path), [input], arena: :exports) do
              [{:ok, out}] -> %{ok: true, b64: Base.encode64(out)}
              [{:error, reason}] -> %{error: inspect(reason)}
            end
        end
      rescue
        e -> %{error: Exception.message(e)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  post "/rcp/toolkit/run" do
    {:ok, body, conn} = read_body(conn)

    args =
      case body do
        "" -> []
        b -> Jason.decode!(b)["args"] || []
      end

    send_resp(conn, 200, Workbooks.Toolkits.run_task_text(conn.params["id"], conn.params["task"], args))
  end

  # `wb fetch` — restore stored bytes (base64-wrapped; zips aren't JSON-safe raw).
  get "/rcp/fetch" do
    t = conn.assigns.tenant
    result = try do
      case Workbooks.Library.fetch(t, conn.params["key"]) do
        {:ok, bytes} -> %{ok: true, b64: Base.encode64(bytes)}
        :error -> %{error: "not found: #{conn.params["key"]}"}
      end
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # did:web (Phase 2e) — the engine's self-hosted identity document. A standard
  # DID resolver fetches this; the key matches the tenant's did:key + ledger.
  get "/.well-known/did.json" do
    host = host_authority(conn)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Workbooks.Did.web_document(host)))
  end

  # Radicle (2f) — federate the tenant repo over the P2P network; returns rad: id.
  post "/api/radicle/:tenant/publish" do
    result =
      try do
        case Workbooks.Git.publish(conn.params["tenant"]) do
          nil -> %{ok: false, error: "radicle not available"}
          rid -> %{ok: true, rid: rid}
        end
      rescue
        e -> %{ok: false, error: Exception.message(e)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # Source rail (2a/2b) — mirror the tenant repo to any git host. {"url": "..."}
  # pushes anywhere; {"forge": "github"|"gitlab"|"gitea"} auto-provisions via its CLI.
  post "/api/mirror/:tenant" do
    {:ok, body, conn} = read_body(conn)
    opts = if body == "", do: %{}, else: Jason.decode!(body)
    tenant = conn.params["tenant"]

    outcome =
      if opts["url"],
        do: Workbooks.Git.mirror(tenant, opts["url"]),
        else: Workbooks.Git.forge_push(tenant, forge: opts["forge"], repo: opts["repo"], visibility: opts["visibility"] || "private")

    result =
      case outcome do
        {:ok, url} -> %{ok: true, url: url}
        {:skip, r} -> %{ok: false, skip: r}
        {:error, e} -> %{ok: false, error: String.slice(to_string(e), 0, 300)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # Ledger verify (Phase 2g) — recompute the hash-chain over the run's current
  # _steps.jsonl and check the did:key signature: tamper-evident + attributable.
  get "/api/ledger/:slug" do
    result = Workbooks.Ledger.verify("/tmp/bb/#{conn.params["slug"]}")
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # Query surface (semantic ∪ literal) — consumer-agnostic; any script/service
  # calls it, not just agents. {"query": "...", "mode": "hybrid"|"semantic"|"literal", "workbook": "..."}
  post "/api/search/:tenant" do
    {:ok, body, conn} = read_body(conn)
    p = Jason.decode!(body)
    mode = String.to_atom(p["mode"] || "hybrid")
    hits = Workbooks.Library.search(conn.params["tenant"], p["query"] || "", mode: mode, workbook: p["workbook"], k: p["k"] || 8)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{hits: hits}))
  end

  # Cross-session index (0d) — every run, newest first, each rolled up. The
  # "see across runs" view for the CLI: catch an error trend, not one run.
  get "/api/telemetry" do
    runs = Workbooks.Workflow.Telemetry.index()
    rollup = %{runs: length(runs), with_errors: Enum.count(runs, &(&1.errors > 0)),
               tool_calls: Enum.reduce(runs, 0, fn r, a -> a + r.tool_calls end)}
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{rollup: rollup, runs: runs}))
  end

  # Browse — the runtime's web capability, reachable over HTTP so any consumer
  # (brandnana harvest, an agent, an external caller) can fetch/crawl/search
  # through the configured provider (free native browser by default).
  #   {"url": "...", "mode": "fetch"|"crawl", "as": "org"|"json"}
  #   {"query": "...", "mode": "search"}
  post "/api/browse" do
    {:ok, body, conn} = read_body(conn)

    try do
      result = browse(Jason.decode!(body))
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
    rescue
      e ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: Exception.message(e)}))
    end
  end

  # The document viewer — a clean, Google-Docs-style reader for Workbooks.
  get "/docs" do
    conn |> put_resp_content_type("text/html") |> send_resp(200, viewer_page())
  end

  get "/api/workbooks" do
    json = Jason.encode!(Workbooks.ControlPlane.list_workbooks())
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  get "/api/w/:id/org" do
    org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
    conn |> put_resp_content_type("text/plain; charset=utf-8") |> send_resp(200, org)
  end

  # Server-rendered HTML — the runtime renders the Org (orgize, in the kernel).
  get "/api/w/:id/html" do
    org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
    conn |> put_resp_content_type("text/html; charset=utf-8") |> send_resp(200, Workbooks.OQL.render(org))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The viewer SPA: the runtime renders Org→HTML server-side (orgize, in the
  # kernel); the page only fetches that HTML + colors code (highlight.js, BSD).
  # No client Org library, no chrome — a clean page.
  # Dispatch a /api/browse request to the Browse capability.
  defp browse(%{"mode" => "search", "query" => q} = p) do
    case Workbooks.Browse.search(q, limit: Map.get(p, "limit", 8)) do
      {:ok, results} -> %{mode: "search", query: q, results: results}
      {:error, reason} -> %{mode: "search", error: inspect(reason)}
    end
  end

  defp browse(%{"mode" => "crawl", "url" => url} = p) do
    {:ok, pages} = Workbooks.Browse.crawl(url, max_pages: Map.get(p, "max_pages", 10))
    render_pages(pages, Map.get(p, "as", "json"))
  end

  defp browse(%{"url" => url} = p) do
    case Workbooks.Browse.fetch(url) do
      {:ok, page} -> render_pages([page], Map.get(p, "as", "json"))
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp render_pages(pages, "org"),
    do: %{count: length(pages), org: Workbooks.Browse.Crawl.to_org(pages)}

  defp render_pages(pages, _),
    do: %{count: length(pages), pages: Enum.map(pages, &Map.take(&1, [:url, :title, :description, :headings]))}

  # The public authority for did:web — prefer the proxy's forwarded host (fly
  # terminates TLS upstream) so the DID id matches the URL clients actually used.
  # Serve a file from <toolkits_root>/<toolkit>/<rel>, path-contained (no escape).
  defp serve_toolkit_file(conn, toolkit, rel) do
    base = Path.expand(Path.join(Workbooks.Toolkits.default_root(), toolkit))
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
  defp json_safe(%_{} = struct), do: struct
  defp json_safe(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, json_safe(v)} end)
  defp json_safe(l) when is_list(l), do: Enum.map(l, &json_safe/1)
  defp json_safe(t) when is_tuple(t), do: inspect(t)
  defp json_safe(other), do: other

  defp host_authority(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-host") do
      [h | _] when is_binary(h) and h != "" -> h
      _ -> conn.host
    end
  end

  defp viewer_page do
    ~S"""
    <!doctype html><html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Workbooks</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github.min.css">
    <style>
    *{box-sizing:border-box} html,body{margin:0;height:100%}
    body{font:16px/1.7 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;color:#202124;background:#f1f3f4;display:flex}
    #tabs{width:264px;height:100vh;overflow:auto;border-right:1px solid #e3e6e8;background:#fff;padding:1.1rem .6rem;flex:0 0 auto}
    #tabs h2{font-size:.66rem;text-transform:uppercase;letter-spacing:.09em;color:#80868b;padding:0 .6rem;margin:.2rem 0 .7rem}
    #tabs a{display:block;padding:.45rem .65rem;border-radius:8px;color:#3c4043;text-decoration:none;font-size:.9rem;cursor:pointer}
    #tabs a:hover{background:#f1f3f4} #tabs a.active{background:#e8f0fe;color:#1a73e8;font-weight:500}
    body>main{flex:1;height:100vh;overflow:auto;display:flex;justify-content:center;padding:3.5rem 1.5rem 6rem}
    #doc{background:#fff;max-width:740px;width:100%;padding:4.5rem 5.5rem;box-shadow:0 1px 3px rgba(60,64,67,.1);border-radius:2px;height:max-content}
    /* orgize wraps content in main/section — normalize them to plain blocks */
    #doc main,#doc section{display:block} #doc p:empty{display:none}
    #doc h1{font-size:1.9rem;font-weight:600;margin:0 0 1rem;letter-spacing:-.01em}
    #doc h2{font-size:1.4rem;font-weight:600;margin:2.2rem 0 .6rem}
    #doc h3{font-size:1.12rem;font-weight:600;margin:1.6rem 0 .4rem}
    #doc p{margin:.85rem 0} #doc a{color:#1a73e8}
    #doc :not(pre)>code,#doc code.inline-code{background:#f1f3f4;padding:.12em .38em;border-radius:5px;font-size:.86em;font-family:"SF Mono",Menlo,Consolas,monospace}
    #doc pre{background:#f8f9fa;border:1px solid #e8eaed;border-radius:10px;padding:1rem 1.25rem;overflow:auto;font-size:.85rem;line-height:1.55}
    #doc table{border-collapse:collapse;width:100%;margin:1.1rem 0;font-size:.93rem}
    #doc th,#doc td{border:1px solid #e8eaed;padding:.5rem .85rem;text-align:left} #doc th{background:#f8f9fa;font-weight:600}
    #doc blockquote{border-left:3px solid #dadce0;margin:1rem 0;padding:.2rem 0 .2rem 1.1rem;color:#5f6368}
    #doc .tag{display:inline-block;background:#e8eaed;color:#5f6368;border-radius:5px;padding:.08em .45em;font-size:.6em;vertical-align:middle;margin-left:.4em;text-transform:lowercase}
    #doc .kw{font-size:.62em;font-weight:700;padding:.18em .5em;border-radius:5px;margin-right:.5em;vertical-align:middle;letter-spacing:.04em}
    #doc .kw-TODO{background:#fce8e6;color:#c5221f} #doc .kw-DONE{background:#e6f4ea;color:#137333}
    #doc .kw-NEXT,#doc .kw-WAIT{background:#feefc3;color:#b06000}
    .empty{color:#80868b}
    </style></head>
    <body>
    <aside id="tabs"><h2>Documents</h2></aside>
    <main><article id="doc"></article></main>
    <script type="module">
    // The runtime renders Org→HTML (orgize, in the kernel). The page only fetches
    // the rendered HTML + colors code (highlight.js, BSD). No client Org library.
    import hljs from "https://esm.sh/highlight.js@11";
    const tabs = document.getElementById("tabs"), docEl = document.getElementById("doc");
    function sanitize(){
      docEl.querySelectorAll("h1,h2,h3,h4").forEach(h=>{
        const first = h.firstChild;
        if(first && first.nodeType===3){
          const m = first.textContent.match(/^\s*(TODO|DONE|NEXT|WAIT|ABANDONED)\b\s*/i);
          if(m){ first.textContent = first.textContent.slice(m[0].length);
            const b=document.createElement("span"); b.className="kw kw-"+m[1].toUpperCase(); b.textContent=m[1].toUpperCase();
            h.insertBefore(b, h.firstChild); }
        }
        h.childNodes.forEach(n=>{ if(n.nodeType===3){ let t=n.textContent.replace(/\s+/g," ").replace(/\s+$/,""); const L=t.replace(/[^A-Za-z]/g,"");
          n.textContent = (L && L===L.toUpperCase()) ? t.toLowerCase().replace(/\b\w/g,c=>c.toUpperCase()) : t; }});
      });
    }
    async function show(id, el){
      document.querySelectorAll("#tabs a").forEach(a=>a.classList.remove("active"));
      if(el) el.classList.add("active");
      docEl.innerHTML = await fetch("/api/w/"+id+"/html").then(r=>r.text());
      docEl.querySelectorAll("pre code").forEach(b=>hljs.highlightElement(b));
      sanitize();
    }
    const list = await fetch("/api/workbooks").then(r=>r.json());
    if(!list.length) docEl.innerHTML = "<p class='empty'>No workbooks yet — PUT one to /w/&lt;id&gt;.</p>";
    list.forEach((id,i)=>{ const a=document.createElement("a"); a.textContent=id; a.onclick=()=>show(id,a);
      tabs.appendChild(a); if(i===0) show(id,a); });
    </script>
    </body></html>
    """
  end

  # A built-in sample until Workbooks are loaded from the VFS / a Bundle.
  defp sample_workbook do
    """
    * Hello, Workbook                                 :workflow:
      SCHEDULED: <2026-06-06 Sat 09:00 +1d>
    ** Greet                                          :component:
       #+begin_src js :out greeting:string
       export default () => "hello from a workbook instance";
       #+end_src
    """
  end

  defp workbook_page(id, rendered) do
    """
    <!doctype html><html><head><meta charset="utf-8"><title>Workbook #{id}</title>
    <style>body{font:15px/1.6 system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;color:#222}
    .tags{color:#aaa;font-weight:400;font-size:.7em}.schedule{color:#0a7}
    .iface{display:grid;grid-template-columns:max-content 1fr;gap:0 .6rem;font-size:.82em;color:#666;margin:.3rem 0}
    pre{background:#f6f7f9;padding:.6rem .8rem;border-radius:6px;overflow:auto}</style></head>
    <body><main id="workbook">#{rendered}</main>
    <script>
      // The Workbook UI talks to its backend — this same runtime. fetch for
      // one-shot calls, a WebSocket for live interaction.
      const ws = new WebSocket((location.protocol === "https:" ? "wss:" : "ws:") + "//" + location.host + "/w/#{id}/ws");
      window.wb = {
        call: (fn, org) => fetch("/w/#{id}/call", {method:"POST",
          headers:{"content-type":"application/json"}, body: JSON.stringify({fn, org})}).then(r => r.json()),
        live: (fn, org) => new Promise(res => { ws.onmessage = e => res(JSON.parse(e.data)); ws.send(JSON.stringify({fn, org})); })
      };
    </script></body></html>
    """
  end
end
