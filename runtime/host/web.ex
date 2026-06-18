defmodule Workbooks.Web do
  @moduledoc """
  The HTTP/WS surface. Authenticate, then create/resume Instances and run SQL
  queries over a workbook's data. Bandit serves this Plug router (opt-in via WB_WEB=1).
  """
  use Plug.Router

  # Helpers factored out by responsibility (p0.4 god-file split): pure render
  # pages, agent picker/prompt, platform-API shaping, and cross-cutting utils.
  # Imported so the route bodies call them by bare name (unchanged behavior).
  import Workbooks.Web.Pages, only: [viewer_page: 0, sample_workbook: 0, workbook_page: 2]
  import Workbooks.Web.Agents, only: [agent_catalog: 1, agent_system_prompt: 1]

  import Workbooks.Web.Platform,
    only: [
      nexus_view: 1,
      provision_opts: 1,
      workspace_params: 1,
      platform_storage_bytes: 1,
      gb: 1,
      reason_str: 1,
      rbac_matrix: 0
    ]

  import Workbooks.Web.Helpers,
    only: [
      org_secret_keys: 0,
      serve_repo_file: 3,
      effective_workdir: 3,
      commands_param: 1,
      harness_sub: 1,
      wb_exec: 2,
      valid_scope: 1,
      library_ask: 2,
      browse: 1,
      serve_toolkit_file: 3,
      json_safe: 1,
      host_authority: 1
    ]

  # CORS (wb-e95f). The desktop runs in a WebKit webview whose origin differs
  # from 127.0.0.1:4000, so every fetch with an Authorization header triggers a
  # preflight OPTIONS. Without this the preflight 404'd (no OPTIONS route) and
  # the real request never fired — breaking voice (system_prompt), workspace
  # sync, and any HTTP engine call. Runs BEFORE Auth so the credential-less
  # preflight isn't rejected. Local engine → allow any origin (it binds
  # loopback / a per-boot-token-gated guest, not the public internet).
  plug(:cors)
  plug(Workbooks.Auth)
  plug(:match)
  plug(:dispatch)

  defp cors(conn, _opts) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "authorization, content-type, x-tenant")
      |> put_resp_header("access-control-max-age", "86400")

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # NOTE: the desktop sign-in broker (/v1/auth/{authorize,callback,exchange}) moved to
  # the cloud dashboard (app.workbooks.sh) — ONE auth front door for web + desktop.
  # See web/cloud-dashboard $lib/desktopBroker. The control plane no longer brokers auth.

  # Live capability dashboard (dev). `capabilities.json` is an agent-maintained
  # ledger (the DSL: capabilities, their tests/units, proof, failure modes);
  # `capabilities.html` self-polls it every few seconds. BOTH are read FRESH per
  # request, so editing the ledger shows up live with NO restart. Public — holds
  # only work-progress metadata, no secrets/tenant data.
  get "/capabilities" do
    serve_repo_file(conn, "capabilities.html", "text/html")
  end

  get "/api/capabilities" do
    serve_repo_file(conn, "capabilities.json", "application/json")
  end

  # Org-provisioned agent keys (wb-xiei.2). An organization can provision the
  # OpenRouter / Gemini keys for its members so onboarding doesn't have to ask — the
  # desktop fetches these on sign-in and applies them locally. Stored per-tenant in
  # Workbooks.Vars (secret); the tenant is the AUTH-verified WorkOS org (OIDC maps
  # `org_id` -> tenant). GET = any org member reads its org's keys; POST sets them
  # (admin-gating is enforced in the dashboard, wb-xiei.4 — this is the storage seam).
  get "/api/org-secrets" do
    tenant = conn.assigns.tenant

    keys =
      for k <- org_secret_keys(),
          v = Workbooks.Vars.host_secret(tenant, k),
          is_binary(v) and v != "",
          into: %{},
          do: {k, v}

    send_json(conn, 200, %{keys: keys})
  end

  post "/api/org-secrets" do
    {:ok, body, conn} = read_body(conn)
    tenant = conn.assigns.tenant
    incoming = (Jason.decode!(body)["keys"] || %{})

    set =
      for {k, v} <- incoming, k in org_secret_keys(), is_binary(v) and v != "" do
        Workbooks.Vars.set(tenant, k, v, true)
        k
      end

    send_json(conn, 200, %{ok: true, set: set})
  end

  # Secret injection (wb-2s09). The desktop holds the user's API keys in the OS
  # keychain; the runtime — especially containerized — can't read that, yet the
  # host-side loaders pull creds from the process ENV (e.g. llm.ex reads
  # OPENROUTER_API_KEY). So the desktop FORWARDS the keys here and we put them on
  # this runtime's env. Token-auth'd (Workbooks.Auth ran above; not @public), so
  # only the local shell holding the per-boot token can set them. An empty body
  # is a harmless no-op nudge. Body: {"env": {"OPENROUTER_API_KEY": "…", …}}.
  post "/internal/secrets/refresh" do
    {:ok, body, conn} = read_body(conn)

    env =
      case String.trim(body) do
        "" -> %{}
        b -> Jason.decode!(b)["env"] || %{}
      end

    for {k, v} <- env, is_binary(k), is_binary(v), v != "" do
      Workbooks.Secrets.put(k, v)
    end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, count: map_size(env)}))
  end

  # Agent system prompt (wb-2s09). The desktop's voice/chat clients fetch the
  # resident agent's persona by slug to seed a session (geminiLive, Waldo). The
  # prompt lives in the profile (`<WB_PROFILE_DIR>/agents/<slug>.html`, under the
  # `** System prompt` heading); a sensible default is returned when the profile
  # has no def for that slug so voice/chat still work out of the box.
  get "/api/agents/:slug/system_prompt" do
    conn = fetch_query_params(conn)
    prompt = agent_system_prompt(conn.params["slug"])
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{system_prompt: prompt}))
  end

  # The desktop bridge's Phoenix-Channels socket (wb-e95f). The phoenix JS client
  # connects here (…/socket/websocket?vsn=2.0.0) and multiplexes its topics
  # (telemetry, desktop:control, env_prompt, …). Workbooks.PhoenixSocket speaks
  # the v2 wire protocol so the bridge connects + stays joined instead of
  # reconnect-looping. Auth: a header-less local upgrade falls to the dev path on
  # the desktop runtime (WB_DESKTOP, unlocked, single-tenant).
  get "/socket/websocket" do
    # Carry the authenticated tenant into the socket so per-session joins/cancels
    # can be gated by ownership (wb-g1yo.2). The upgrade conn already passed the
    # Auth plug, so conn.assigns.tenant is set.
    conn
    |> WebSockAdapter.upgrade(Workbooks.PhoenixSocket, %{tenant: conn.assigns[:tenant]}, timeout: 60_000)
    |> halt()
  end

  # Voice agent audio socket (wb-091n). Client-side Moonshine sends finalized
  # transcripts + barge-in signals as JSON; the server streams Inworld TTS audio
  # back as binary PCM frames. The INWORLD_API_KEY stays host-side.
  get "/api/voice/:session_id" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.Voice.Stream, %{session_id: conn.params["session_id"]}, timeout: 600_000)
    |> halt()
  end

  # Workspace sync (wb-e95f). The desktop's offline-first registry calls this to
  # reconcile local workspaces with the engine. This runtime keeps no remote
  # workspace registry, so it acks (local-first) and the desktop just refreshes
  # its local store — stops the 404 the bridge otherwise swallowed silently.
  get "/api/workspaces/sync" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, synced: false, workspaces: []}))
  end

  # Web search for the desktop browser's composable-search "Web" provider
  # (wb-aakl.19). The browser sends no SERP keys; the nexus resolves the
  # tenant's configured provider from Settings (Vars: wb.search.provider + its
  # keyed secret) — falling back to keyless ddg/brave/bing when none is set —
  # and returns [{title,url,snippet}]. An explicit ?provider= overrides for a
  # one-off. GET so the browser's fetch is trivial.
  get "/api/browse/search" do
    conn = fetch_query_params(conn)
    {q, opts} = Workbooks.Browse.Search.parse_request(conn.query_params, conn.assigns[:tenant])

    results = if q == "", do: [], else: Workbooks.Browse.Search.query(q, opts)

    json = Jason.encode!(%{results: results})
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end


  # RCP handshake (RUNTIME-CONNECT-PROTOCOL.md §1): unauthenticated capabilities
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
    Workbooks.Workflow.Telemetry.tag_tenant(workdir, conn.assigns[:tenant])
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
    json = Jason.encode!(Workbooks.ControlPlane.list(conn.assigns[:tenant]))
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # ── Platform control-plane API (the hosted "nexus" dashboard) ──────────────────
  # tenant = the owning org (the Auth plug maps a WorkOS-issued JWT's org → :tenant).
  # Every call is org-scoped through NexusRegistry / NexusProvisioner (WHERE org_id =
  # tenant), so a caller can only ever see or act on its OWN nexuses — ownership IDOR
  # is closed at the data layer, not re-derived here.
  get "/api/platform/nexuses" do
    org = conn.assigns[:tenant]
    j(conn, 200, %{nexuses: Enum.map(Workbooks.NexusRegistry.list(org), &nexus_view/1)})
  end

  post "/api/platform/nexuses" do
    org = conn.assigns[:tenant]
    {:ok, body, conn} = read_body(conn)

    case Workbooks.NexusProvisioner.provision(org, provision_opts(body)) do
      {:ok, nx} -> j(conn, 201, nexus_view(nx))
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  get "/api/platform/nexuses/:id" do
    org = conn.assigns[:tenant]

    case Workbooks.NexusRegistry.get(conn.params["id"], org) do
      {:ok, nx} -> j(conn, 200, nexus_view(nx))
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
    end
  end

  delete "/api/platform/nexuses/:id" do
    org = conn.assigns[:tenant]
    platform_lifecycle(conn, fn -> Workbooks.NexusProvisioner.teardown(conn.params["id"], org) end)
  end

  post "/api/platform/nexuses/:id/wake" do
    org = conn.assigns[:tenant]
    platform_lifecycle(conn, fn -> Workbooks.NexusProvisioner.wake(conn.params["id"], org) end)
  end

  post "/api/platform/nexuses/:id/sleep" do
    org = conn.assigns[:tenant]
    platform_lifecycle(conn, fn -> Workbooks.NexusProvisioner.sleep(conn.params["id"], org) end)
  end

  # Real Fly-grounded usage + cost rollup for the org (compute from machine event logs).
  get "/api/platform/usage" do
    j(conn, 200, Workbooks.NexusUsage.rollup(conn.assigns[:tenant]))
  end

  # The signed-in user's identity + the ORGS they belong to, each with their role.
  # An org ≈ a nexus (the isolation unit), so this powers the desktop/dashboard
  # org/nexus switcher. `active_org` is the org of the current token. Fail-soft:
  # without a WorkOS API key (or for a personal/no-org session) `orgs` is [].
  get "/api/platform/me" do
    claims = me_claims(conn)
    user_id = claims["sub"]

    j(conn, 200, %{
      user: %{id: user_id, name: claims["name"] || claims["given_name"] || ""},
      active_org: conn.assigns[:tenant],
      orgs: if(is_binary(user_id), do: Workbooks.WorkOS.orgs_for_user(user_id), else: [])
    })
  end

  # Real per-org storage total + a bucket per nexus.
  get "/api/platform/storage" do
    org = conn.assigns[:tenant]
    nexuses = Workbooks.NexusRegistry.list(org)
    total = platform_storage_bytes(org)

    buckets =
      Enum.map(nexuses, fn nx ->
        %{name: "#{nx[:id]}-storage", nexus: nx[:id], objects: nil, size: "—", egress: "$0.00"}
      end)

    j(conn, 200, %{totalBytes: total, totalSize: gb(total), buckets: buckets})
  end

  # ── Workspaces: FREE, named divisions within the org (no compute) ──────────────
  # A workspace runs on a nexus but creating one provisions nothing — it's a logical
  # partition. Org-scoped via the tenant, same isolation rule as nexuses.
  get "/api/platform/workspaces" do
    j(conn, 200, %{workspaces: Workbooks.WorkspaceRegistry.list(conn.assigns[:tenant])})
  end

  post "/api/platform/workspaces" do
    org = conn.assigns[:tenant]
    {:ok, body, conn} = read_body(conn)
    %{name: name, icon: icon, nexus_id: nexus_id} = workspace_params(body)

    case Workbooks.WorkspaceRegistry.create(org, name, icon: icon, nexus_id: nexus_id) do
      {:ok, ws} -> j(conn, 201, ws)
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  patch "/api/platform/workspaces/:id" do
    org = conn.assigns[:tenant]
    {:ok, body, conn} = read_body(conn)
    # Only the keys the caller included — PATCHing just the icon must not blank the name.
    attrs = case Jason.decode(body) do
      {:ok, %{} = m} -> Map.take(m, ["name", "icon"])
      _ -> %{}
    end

    case Workbooks.WorkspaceRegistry.update(conn.params["id"], org, attrs) do
      {:ok, ws} -> j(conn, 200, ws)
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  delete "/api/platform/workspaces/:id" do
    org = conn.assigns[:tenant]
    platform_lifecycle(conn, fn -> Workbooks.WorkspaceRegistry.delete(conn.params["id"], org) end)
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
    page = workbook_page(id, org)
    conn |> put_resp_content_type("text/html") |> send_resp(200, page)
  end

  # The Workbook's backend: the served page calls home to its own runtime.
  post "/w/:id/call" do
    {:ok, body, conn} = read_body(conn)
    %{"fn" => fun, "org" => org} = Jason.decode!(body)

    result =
      case fun do
        "parse" -> Workbooks.Workbook.parse_headlines(org)
        "tangle" -> Workbooks.Workbook.tangle_plan(org)
        "validate" -> Workbooks.Workbook.validate(org)
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
      # exec is a TRUST grant: it gives the agent the HOST-BROKERED git/publish
      # tools and routes its filesystem tools at the OS workdir. It does NOT grant
      # any native execution — the `run` bash hatch was deleted (wb-9ja). Honored
      # ONLY for the trusted local case (single-tenant/desktop) or an explicit
      # WB_AGENT_EXEC=1 — never for arbitrary/multi-tenant callers.
      |> then(fn o ->
        allow? = Workbooks.Desktop.enabled?() or System.get_env("WB_AGENT_EXEC") == "1"
        if params["exec"] == true and allow?, do: [{:exec, true} | o], else: o
      end)

    {:ok, _} = Workbooks.AgentSession.start(id, system, task, opts)
    json = Jason.encode!(%{id: id, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # Desktop chat entry (wb-2s09): the desktop's ws.sendUserInput POSTs here with
  # {agent_slug, prompt, workdir?, skills?}. We resolve the SLUG to its system
  # prompt, start a session (whose events the PhoenixSocket bridge streams to the
  # joined session:<id> channel), and return {session_id}. Mirrors /api/run but
  # slug-resolving — without it the desktop got a 404 and Waldo never replied.
  post "/api/agent/run" do
    {:ok, body, conn} = read_body(conn)
    params = Jason.decode!(body)
    slug = params["agent_slug"] || "waldo"
    prompt = params["prompt"] || ""

    system =
      case params["skills"] do
        skills when is_list(skills) and skills != [] ->
          agent_system_prompt(slug) <> "\n\nAttached skills (read with `work kit show`): " <> Enum.join(skills, ", ")

        _ ->
          agent_system_prompt(slug)
      end

    id = "run-#{System.unique_integer([:positive])}"
    exec? = Workbooks.Desktop.enabled?() or System.get_env("WB_AGENT_EXEC") == "1"

    # The tenant's own model choice (wb-g1yo / wb-d2nx.5), if they set one via
    # `work model set` — per-tenant, not the process-global default.
    tenant_model =
      case Workbooks.Vars.get(conn.assigns.tenant, "wb.model") do
        {:ok, m} -> m
        _ -> nil
      end

    # Workdir confinement (wb-g1yo.4b): the DESKTOP (trusted, single-tenant) may
    # name its own local workbook path; a CLOUD/shared caller MUST NOT — a
    # user-supplied workdir there is path-traversal + cross-tenant FS. So on
    # cloud, ignore params["workdir"] and use a confined per-tenant scratch dir.
    workdir = effective_workdir(conn.assigns.tenant, id, params["workdir"])

    opts =
      [tenant: conn.assigns.tenant, max_steps: 40, exec: exec?, workdir: workdir]
      |> then(&if tenant_model, do: [{:model, tenant_model} | &1], else: &1)

    {:ok, _} = Workbooks.AgentSession.start(id, system, prompt, opts)
    Workbooks.SessionLedger.record(id, slug, prompt, workdir, conn.assigns.tenant)
    json = Jason.encode!(%{session_id: id, status: "running"})
    conn |> put_resp_content_type("application/json") |> send_resp(202, json)
  end

  # In-wasm HARNESS session entrypoint (acp-cloud-enable, gaps #1/#2). The PRODUCTION web path that
  # creates/looks up a resident StarlingMonkey harness session bound to the AUTH-VERIFIED tenant. This is the
  # binding the audit found MISSING (the surface was pid-driven thesis-only with no request path carrying
  # identity). Identity is NEVER caller-supplied:
  #   * `conn.assigns.tenant` is the verified tenant (Workbooks.Auth — in multi-tenant the anon/x-tenant
  #     fallback is already rejected by the auth plug + Tenancy);
  #   * `HarnessPool.start_session/2` namespaces the session id by that tenant AND overrides the grant
  #     principal + creds_scope.user with it, so a caller cannot charge/scope another tenant;
  #   * the fs workdir is the per-tenant confined scratch (effective_workdir) — never a caller path;
  #   * the per-tenant resident-instance cap + global ceiling apply (host OOM defense).
  # Body: {session?, exec?, commands?, creds_provider?}. Returns {session_id, status} | a cap/denied error.
  post "/api/harness/session" do
    {:ok, body, conn} = read_body(conn)
    params = if body == "", do: %{}, else: Jason.decode!(body)
    tenant = conn.assigns.tenant

    # SANITIZE the caller-supplied session sub-id to a single flat path segment
    # BEFORE it touches the FS workdir or the namespaced Registry/ETS key. The
    # caller controls `params["session"]`; left raw it interpolated into both the
    # run_id (-> path-traversal escape of the per-tenant scratch root) and the
    # global session key. One sanitize at the boundary closes both.
    sub = harness_sub(params["session"])
    workdir = effective_workdir(tenant, "harness-#{sub}", nil)

    # exec is a TRUST grant; honored only for the trusted local case or explicit WB_AGENT_EXEC — never for an
    # arbitrary multi-tenant caller (same posture as /api/run). The principal is forced to the tenant by the
    # pool regardless of what the caller passes.
    exec_allowed? = Workbooks.Desktop.enabled?() or System.get_env("WB_AGENT_EXEC") == "1"
    want_exec? = params["exec"] == true and exec_allowed?

    exec_grant =
      [allow: want_exec?, commands: commands_param(params["commands"]), principal: tenant]
      |> then(fn g ->
        case params["creds_provider"] do
          p when is_binary(p) and p != "" -> Keyword.put(g, :creds_scope, %{user: tenant, provider: p})
          _ -> g
        end
      end)

    opts = [session: sub, exec: exec_grant, fs: [workdir: workdir, principal: tenant]]

    case Workbooks.HarnessPool.start_session(tenant, opts) do
      {:ok, _pid} ->
        send_json(conn, 202, %{session_id: Workbooks.HarnessPool.namespaced_id(tenant, sub), status: "live"})

      {:error, :tenant_session_cap} ->
        send_json(conn, 429, %{error: "per-tenant harness session cap reached"})

      {:error, :host_session_cap} ->
        send_json(conn, 503, %{error: "host harness capacity reached"})

      {:error, reason} ->
        send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # Session list + navigation (wb-kbq5 / wb-t3mr): the desktop browses past
  # conversations here. ?active=true narrows to running. Empty until a chat runs.
  get "/api/sessions" do
    conn = fetch_query_params(conn)
    active_only? = conn.query_params["active"] == "true"
    # Tenant-scoped (wb-g1yo.1): a caller sees only their own tenant's sessions.
    sessions = Workbooks.SessionLedger.list(conn.assigns.tenant, active_only?)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{sessions: sessions}))
  end

  # Engine identity for the settings "About" pane (wb-kbq5). Soft-fails to null
  # on the desktop, but a real payload lets it show the version/build it runs on.
  get "/api/about" do
    doc = Workbooks.Web.Capabilities.doc()

    about = %{
      version: doc[:runtime] || doc["runtime"] || "0.1.0",
      tenancy: doc[:tenancy] || doc["tenancy"] || "single",
      mode: if(Workbooks.Desktop.enabled?(), do: "desktop", else: "server")
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(about))
  end

  # Voice/agent command exec (wb-kbq5): the Gemini voice agent's bash tool POSTs
  # {command} here. NO native bash (wb-9ja) — a `work …` command runs the real CLI
  # (incl. `work app …` desktop control), anything else runs in the safe in-WASM
  # shell (cat/grep/jq/pipes). Returns {output} | {error}.
  post "/api/agents/:slug/exec" do
    {:ok, body, conn} = read_body(conn)
    command = (Jason.decode!(body)["command"] || "") |> to_string()
    tenant = conn.assigns.tenant

    result =
      case OptionParser.split(command) do
        ["wb" | argv] -> %{output: wb_exec(argv, tenant)}
        [] -> %{output: ""}
        _ ->
          case Workbooks.Shell.run(command, "", dirs: []) do
            {:ok, out} -> %{output: out}
            {:error, e} -> %{error: inspect(e)}
          end
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # IDOR guard (wb-g1yo.9): a `:tenant` PATH param must equal the authenticated
  # caller's tenant. A nil caller (admin/internal/dev-unset) is grandfathered.
  defp path_tenant_ok?(conn),
    do: Workbooks.Tenant.visible?(conn.params["tenant"], conn.assigns[:tenant])

  # Session-ownership guard (wb-g1yo.9): only the run's owning tenant may act on
  # it by id (CTK review pull/commit). Same grandfather rule; a not-found run is
  # left to the underlying op (which returns :not_found).
  defp session_owner_ok?(conn, id) do
    caller = conn.assigns[:tenant]

    case Workbooks.AgentSession.status(id) do
      %{tenant: st} -> Workbooks.Tenant.visible?(st, caller)
      _ -> true
    end
  rescue
    _ -> true
  end

  # Workbook-as-memory (wb-kbq5.1): the desktop loads workbook files as semantic
  # memory sources. GET lists loaded paths; POST {path} indexes; DELETE {path}
  # drops. Matches the desktop memory_sources store shapes.
  get "/api/memory/sources" do
    workbooks = Workbooks.MemorySources.list(conn.assigns.tenant)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{workbooks: workbooks}))
  end

  post "/api/memory/sources" do
    {:ok, body, conn} = read_body(conn)
    path = Jason.decode!(body)["path"]

    case Workbooks.MemorySources.load(conn.assigns.tenant, to_string(path)) do
      {:ok, %{indexed_count: n, file_count: fc}} ->
        send_json(conn, 200, %{workbook_path: path, indexed_count: n, file_count: fc})

      {:error, reason} ->
        send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  delete "/api/memory/sources" do
    {:ok, body, conn} = read_body(conn)
    path = Jason.decode!(body)["path"]

    case Workbooks.MemorySources.remove(conn.assigns.tenant, to_string(path)) do
      {:ok, %{entry_count: n, file_count: fc}} -> send_json(conn, 200, %{entry_count: n, file_count: fc})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # Skill catalog for the @-picker (wb-kbq5). User/project SKILL.md authoring
  # isn't wired yet, so this is an empty-but-valid catalog (stops the 404; the
  # picker degrades to empty). Real discovery tracked as follow-up.
  get "/api/skills" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{skills: []}))
  end

  # Command palette "ask" (wb-kbq5): a one-shot LLM answer for the ⌘/ palette.
  # Returns {mode:"answer",text} to show in-modal (the desktop also accepts a
  # {mode:"write",text} to inject into the composer; we answer by default).
  post "/api/palette/ask" do
    {:ok, body, conn} = read_body(conn)
    params = Jason.decode!(body)
    prompt = params["prompt"] || ""
    composer = params["composer_text"] || ""

    system =
      "You are the Workbooks command-palette assistant. Answer the user's request " <>
        "directly and concisely in plain text. If a draft is shown, help refine it."

    user = if composer != "", do: "Current draft:\n#{composer}\n\nRequest: #{prompt}", else: prompt

    payload =
      case Workbooks.Llm.complete([%{role: "system", content: system}, %{role: "user", content: user}]) do
        {:ok, %{content: text}} when is_binary(text) and text != "" -> %{mode: "answer", text: text}
        {:error, reason} -> %{error: "llm", detail: inspect(reason)}
        _ -> %{mode: "answer", text: "(no response)"}
      end

    status = if Map.has_key?(payload, :error), do: 502, else: 200
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  # Agent picker catalog (wb-kbq5): project-scope (<workdir>/.workbooks/agents/*.html) →
  # user-scope (WB_PROFILE_DIR/agents/*.html) → the builtin Waldo. The desktop's
  # agents.svelte refreshes this; without it the picker was empty (404).
  get "/api/agents/list" do
    conn = fetch_query_params(conn)
    agents = agent_catalog(conn.query_params["workdir"])
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{agents: agents}))
  end

  # Live agent telemetry — each tool step streamed as it happens (brandnana-style).
  get "/api/run/:id/stream" do
    conn
    |> WebSockAdapter.upgrade(Workbooks.AgentStream, %{id: conn.params["id"]}, timeout: 600_000)
    |> halt()
  end

  # Poll an agent run's status + result + observable events.html.
  get "/api/run/:id" do
    id = conn.params["id"]
    t = conn.assigns[:tenant]

    reply =
      case Workbooks.AgentSession.status(id) do
        # Live run: tenant-gate (wb-g1yo.2) — another tenant can't read it; fall
        # through to a persisted transcript only if THEY own one.
        %{tenant: st} = s ->
          if is_nil(t) or is_nil(st) or st == t,
            do: s,
            else: Workbooks.SessionLedger.transcript(id, t) || %{error: "no such run"}

        # Not live (completed/restarted): serve the persisted transcript (wb-g1yo.8),
        # tenant-gated.
        _ ->
          Workbooks.SessionLedger.transcript(id, t) || %{error: "no such run"}
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

        # Only the run's owner may commit a review into it (wb-g1yo.9).
        not session_owner_ok?(conn, run_id) ->
          {404, %{error: "no such run", run: run_id}}

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
    # Only the run's owner may pull its pending review (wb-g1yo.9).
    review_result =
      if session_owner_ok?(conn, conn.params["id"]),
        do: Workbooks.AgentSession.take_review(conn.params["id"]),
        else: :not_found

    case review_result do
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
    Workbooks.Workflow.Telemetry.tag_tenant(workdir, conn.assigns[:tenant])
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
    Workbooks.Workflow.Telemetry.tag_tenant(workdir, conn.assigns[:tenant])
    File.write(Path.join(workdir, "_status.json"), Jason.encode!(%{slug: slug, request: request, stage: "running"}))

    spawn(fn ->
      def_path = "#{Workbooks.Config.profile_dir()}/agents/brandnana.html"
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
    slug = conn.params["slug"]
    wd = "/tmp/bb/#{slug}"

    # Tenant-gate + path-safe (wb-g1yo.9): a slug can't escape /tmp/bb, and you
    # can't poll another tenant's brand-book run by its slug.
    body =
      cond do
        String.contains?(slug, "/") or String.contains?(slug, "..") ->
          Jason.encode!(%{error: "bad slug"})

        not Workbooks.Workflow.Telemetry.run_visible?(wd, conn.assigns[:tenant]) ->
          Jason.encode!(%{error: "no such run", slug: slug})

        true ->
          case File.read(Path.join(wd, "_status.json")) do
            {:ok, j} -> j
            _ -> Jason.encode!(%{error: "no such run", slug: slug})
          end
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # Telemetry feedback loop (CLI reads this): task states + tool-call count +
  # total time + errors (bash exit codes / tool failures) for a run.
  get "/api/telemetry/:slug" do
    wd = "/tmp/bb/#{conn.params["slug"]}"
    # Tenant-gate (wb-g1yo.3): don't serve another tenant's run telemetry.
    if Workbooks.Workflow.Telemetry.run_visible?(wd, conn.assigns[:tenant]) do
      summary = Workbooks.Workflow.Telemetry.summary(wd)
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(summary))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(404, Jason.encode!(%{error: "no such run"}))
    end
  end

  # Library (Phase 3) — the tenant's access graph: workspaces + their members.
  get "/api/library/:tenant" do
    # IDOR guard (wb-g1yo.9): the path tenant must be the CALLER's tenant — you
    # can't read another tenant's library by changing the URL.
    if path_tenant_ok?(conn) do
      wss = Workbooks.Library.workspaces(conn.params["tenant"])
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{workspaces: wss}))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  # Cross-workbook SQL query-through across a Library's members. {"sql": "..."}
  post "/api/library/:tenant/query" do
    {:ok, body, conn} = read_body(conn)

    if path_tenant_ok?(conn) do
      sql = Jason.decode!(body)["sql"] || ""
      result = Workbooks.Library.query(conn.params["tenant"], sql)
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  # ── RCP engine verbs for the `work` CLI (token → tenant; see cli/TAXONOMY.md) ──
  # These mirror the escript's local Library.* calls, but token-authed so the thin
  # Rust CLI can drive a running engine. Tenant comes from the credential, not a path.

  # `work build` — compile a workspace's components → WASM.
  post "/rcp/build" do
    t = conn.assigns.tenant
    slug = conn.params["src"] || conn.params["slug"] || "."
    result = try do
      Workbooks.Library.build(t, slug)
    rescue e -> %{error: Exception.message(e)} end
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # `work checkout` / `work checkin` — borrow a library member / pack it back.
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

  # `work bundle` over RCP — the engine-side home of the format for callers (the
  # desktop, a remote CLI) whose working tree isn't on the engine's filesystem.
  # BYTES in, BYTES out, same as checkout/checkin: the caller packs its dir tree
  # into the SAME :zip parts map (Workbooks.Bundle.pack) and ships it b64; the
  # engine derives the page html, embeds the bundle + the hydration loader, and
  # (when sign=1) signs it as the tenant via Workbooks.Manifest — so the returned
  # .html is byte-identical to what `Workbooks.CLI.call(["bundle", …])` writes.
  # No second bundler anywhere: this is `Workbooks.Bundle`, the one home. The
  # caller ships a raw parts map (`files: %{"rel/path" => base64-bytes}`) — NOT a
  # pre-built zip — so the desktop shell only does file IO, never any zip/embed/
  # sign work. All of that is `Workbooks.Bundle` on the engine.
  post "/rcp/bundle" do
    {:ok, body, conn} = read_body(conn, length: 100_000_000)
    t = conn.assigns.tenant

    result =
      try do
        %{"files" => files} = Jason.decode!(body)
        parts = Map.new(files, fn {k, v} -> {k, Base.decode64!(v)} end)
        blob = Workbooks.Bundle.pack(parts)

        html = parts["index.html"] || parts["workbook.html"] || ""

        html = html |> Workbooks.Bundle.embed(blob) |> Workbooks.Bundle.embed_loader()
        sign? = Plug.Conn.fetch_query_params(conn).query_params["sign"] == "1"
        html = if sign?, do: Workbooks.Bundle.sign_embedded(html, t), else: html
        %{ok: true, html_b64: Base.encode64(html), files: Map.keys(parts)}
      rescue
        e -> %{error: Exception.message(e)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # `work unbundle` over RCP — inverse of the above. The caller ships the .html
  # bytes b64; the engine extracts + unpacks the embedded bundle and returns the
  # raw parts map (`files: %{"rel/path" => base64-bytes}`) so the desktop shell
  # only writes bytes to disk — no engine-side path, no Rust unzip.
  post "/rcp/unbundle" do
    {:ok, body, conn} = read_body(conn, length: 100_000_000)

    result =
      try do
        %{"b64" => b64} = Jason.decode!(body)
        html = Base.decode64!(b64)

        case Workbooks.Bundle.extract(html) do
          nil ->
            %{error: "no wb-bundle in html"}

          blob ->
            files = Map.new(Workbooks.Bundle.unpack(blob), fn {k, v} -> {k, Base.encode64(v)} end)
            %{ok: true, files: files}
        end
      rescue
        e -> %{error: Exception.message(e)}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
  end

  # `work store` / `work store --list` — archive a workspace / list stored keys.
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

  # ── `work kit` — the agent-extensibility surface over RCP ─────────────────
  # Mirrors the escript verbs (WorkKits.*_text) so a REMOTE/containerized engine
  # is reachable from the thin CLI. Text in/out — these are help-surface +
  # build/run verbs, not data APIs. Task execution stays server-side gated
  # (WB_TOOLKIT_EXEC=1 default-deny + Sandbox, see Workbooks.WorkKits).

  get "/rcp/toolkit" do
    send_resp(conn, 200, Workbooks.WorkKits.list_text())
  end

  get "/rcp/toolkit/show" do
    out =
      case conn.params["skill"] do
        s when s in [nil, ""] -> Workbooks.WorkKits.show_text(conn.params["id"])
        skill -> Workbooks.WorkKits.show_skill_text(conn.params["id"], skill)
      end

    send_resp(conn, 200, out)
  end

  get "/rcp/toolkit/search" do
    send_resp(conn, 200, Workbooks.WorkKits.search_text(conn.params["q"] || ""))
  end

  post "/rcp/toolkit/verify" do
    send_resp(conn, 200, Workbooks.WorkKits.verify_text(conn.params["id"]))
  end

  # Run a toolkit's eval suite server-side (NIFs + LLM available here; bash/agent
  # execution gated by the runtime's WB_TOOLKIT_EXEC). The thin CLI hits this.
  post "/rcp/toolkit/eval" do
    conn = fetch_query_params(conn)
    # ?case=<substring> runs just ONE eval case; ?model=<id> overrides WB_EVAL_MODEL
    # for that run (the "re-run a failing eval with a stronger model" triage step).
    out = Workbooks.WorkKits.eval_text(conn.query_params["id"], Workbooks.WorkKits.default_root(), conn.query_params["case"], conn.query_params["model"])
    send_resp(conn, 200, out)
  end

  post "/rcp/toolkit/build" do
    out =
      case conn.params["which"] do
        w when w in [nil, ""] -> Workbooks.WorkKits.build_text(conn.params["id"])
        which -> Workbooks.WorkKits.build_text(conn.params["id"], which, Workbooks.WorkKits.default_root())
      end

    send_resp(conn, 200, out)
  end

  post "/rcp/toolkit/sign" do
    send_resp(conn, 200, Workbooks.WorkKits.sign_text(conn.params["id"], conn.assigns.tenant))
  end

  # Versioned releases (work-verbs): list versions, show the live pin, roll back.
  get "/rcp/toolkit/versions" do
    send_resp(conn, 200, Workbooks.WorkKits.versions_text(conn.params["id"]))
  end

  get "/rcp/toolkit/live" do
    out =
      case conn.params["id"] do
        id when id in [nil, ""] -> Workbooks.WorkKits.live_text()
        id -> Workbooks.WorkKits.live_text(id, Workbooks.WorkKits.default_root())
      end

    send_resp(conn, 200, out)
  end

  post "/rcp/toolkit/rollback" do
    send_resp(conn, 200, Workbooks.WorkKits.rollback_text(conn.params["id"], conn.params["version"]))
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

  # `work kit push` — install a toolkit DIRECTORY onto this engine (zip b64).
  # The deploy-the-toolkit verb: deployment.org declares it, deploy applies it.
  # Guards: id charset, zip-slip containment under the toolkits root.
  post "/rcp/toolkit/install" do
    {:ok, body, conn} = read_body(conn, length: 50_000_000)
    id = conn.params["id"] || ""

    out =
      cond do
        not Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, id) ->
          "refused: bad toolkit id #{inspect(id)}"

        true ->
          try do
            %{"b64" => b64} = Jason.decode!(body)
            root = Path.expand(Workbooks.WorkKits.default_root())
            dest = Path.join(root, id)
            File.mkdir_p!(dest)

            for {name, content} <- Workbooks.Bundle.unpack(Base.decode64!(b64)) do
              path = Path.expand(Path.join(dest, name))

              if String.starts_with?(path, dest <> "/") or path == dest do
                File.mkdir_p!(Path.dirname(path))
                File.write!(path, content)
              end
            end

            "installed toolkit #{id} → #{dest} (#{length(Workbooks.WorkKits.skills(dest))} skills)"
          rescue
            e -> "install failed: " <> Exception.message(e)
          end
      end

    send_resp(conn, 200, out)
  end

  post "/rcp/toolkit/run" do
    {:ok, body, conn} = read_body(conn)

    args =
      case body do
        "" -> []
        b -> Jason.decode!(b)["args"] || []
      end

    send_resp(conn, 200, Workbooks.WorkKits.run_task_text(conn.params["id"], conn.params["task"], args))
  end

  # lander-live (wb-5vm): the page's PUBLIC change feed — the tenant repo's real
  # git log, newest first. The inspector's "agent" tab reads this; the whole
  # point is that the changelog is verifiable history, not marketing.
  get "/rcp/changes" do
    t = conn.assigns.tenant
    entries =
      Workbooks.Git.log(t)
      |> Enum.take(30)
      |> Enum.map(fn line ->
        case String.split(line, " ", parts: 2) do
          [sha, msg] -> %{sha: sha, msg: msg}
          [sha] -> %{sha: sha, msg: ""}
        end
      end)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{changes: entries}))
  end

  # `work fetch` — restore stored bytes (base64-wrapped; zips aren't JSON-safe raw).
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
    # IDOR guard (wb-g1yo.9): can't publish another tenant's repo.
    if path_tenant_ok?(conn) do
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
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{ok: false, error: "forbidden"}))
    end
  end

  # Source rail (2a/2b) — mirror the tenant repo to any git host. {"url": "..."}
  # pushes anywhere; {"forge": "github"|"gitlab"|"gitea"} auto-provisions via its CLI.
  post "/api/mirror/:tenant" do
    {:ok, body, conn} = read_body(conn)

    # IDOR guard (wb-g1yo.9): mirroring pushes the tenant's WHOLE repo to a
    # caller-supplied git URL — a cross-tenant call here is repo exfiltration.
    if path_tenant_ok?(conn) do
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
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{ok: false, error: "forbidden"}))
    end
  end

  # Ledger verify (Phase 2g) — recompute the hash-chain over the run's current
  # _steps.jsonl and check the did:key signature: tamper-evident + attributable.
  get "/api/ledger/:slug" do
    slug = conn.params["slug"]
    wd = "/tmp/bb/#{slug}"

    # Tenant-gate + path-safe (wb-g1yo.9): a run ledger (tamper/attribution status)
    # is another tenant's; the slug also can't escape /tmp/bb.
    cond do
      String.contains?(slug, "/") or String.contains?(slug, "..") ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: "bad slug"}))

      not Workbooks.Workflow.Telemetry.run_visible?(wd, conn.assigns[:tenant]) ->
        conn |> put_resp_content_type("application/json") |> send_resp(404, Jason.encode!(%{error: "no such run"}))

      true ->
        result = Workbooks.Ledger.verify(wd)
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))
    end
  end

  # Query surface (semantic ∪ literal) — consumer-agnostic; any script/service
  # calls it, not just agents. {"query": "...", "mode": "hybrid"|"semantic"|"literal", "workbook": "..."}
  post "/api/search/:tenant" do
    {:ok, body, conn} = read_body(conn)

    # IDOR guard (wb-g1yo.9): can't search another tenant's library.
    if path_tenant_ok?(conn) do
      p = Jason.decode!(body)
      mode = String.to_atom(p["mode"] || "hybrid")
      hits = Workbooks.Library.search(conn.params["tenant"], p["query"] || "", mode: mode, workbook: p["workbook"], k: p["k"] || 8)
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{hits: hits}))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, Jason.encode!(%{error: "forbidden"}))
    end
  end

  # AI-over-files (wb-ndlz): search the AUTHED tenant's own library, then synthesize a
  # GROUNDED answer that cites the files — never inventing what isn't there. Backend for
  # the desktop's right-bar "ai" search mode (replacing its mock). Auth-tenant (like
  # /api/browse/search) — you only ever ask YOUR own files, so no path tenant to know.
  # Returns {answer, sources:[{title,path,snippet}], related} to match the AiAnswer contract.
  post "/api/library/ask" do
    {:ok, body, conn} = read_body(conn)
    p = Jason.decode!(body)
    query = String.trim(p["query"] || "")
    tenant = conn.assigns[:tenant]
    hits = if query == "" or is_nil(tenant), do: [], else: Workbooks.Library.search(tenant, query, mode: :hybrid, k: 6)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(library_ask(query, hits)))
  end

  # Cross-session index (0d) — every run, newest first, each rolled up. The
  # "see across runs" view for the CLI: catch an error trend, not one run.
  get "/api/telemetry" do
    runs = Workbooks.Workflow.Telemetry.index(conn.assigns[:tenant])
    rollup = %{runs: length(runs), with_errors: Enum.count(runs, &(&1.errors > 0)),
               tool_calls: Enum.reduce(runs, 0, fn r, a -> a + r.tool_calls end)}
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{rollup: rollup, runs: runs}))
  end

  # ── Channels (messaging adapters, official-API tier) ────────────────────────
  # Runtime capability, not an agent tool: creds stay runtime-side (env), the
  # control plane just lists/sends/approves. See Workbooks.Channels.

  get "/api/channels" do
    json = Jason.encode!(%{channels: Workbooks.Channels.list()})
    conn |> put_resp_content_type("application/json") |> send_resp(200, json)
  end

  # {"channel": "telegram", "peer": "<chat id>", "text": "...", "parse_mode": "Markdown"?}
  post "/api/channels/send" do
    {:ok, body, conn} = read_body(conn)
    p = Jason.decode!(body)
    opts = if pm = p["parse_mode"], do: [parse_mode: pm], else: []

    case Workbooks.Channels.send(p["channel"] || "", p["peer"], p["text"] || "", opts) do
      {:ok, sent} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, sent: sent}))

      {:error, :unknown_channel} ->
        Workbooks.Web.Error.render(conn, :bad_request, "unknown channel: #{p["channel"]}")

      {:error, :not_configured} ->
        Workbooks.Web.Error.render(conn, :unavailable, "channel not configured: #{p["channel"]}")

      {:error, reason} ->
        Workbooks.Web.Error.render(conn, :unavailable, "send failed: #{inspect(reason)}")
    end
  end

  # DM-policy pairing: {"channel": "telegram", "code": "ABC123"} → allowlist the peer.
  post "/api/channels/approve" do
    {:ok, body, conn} = read_body(conn)
    p = Jason.decode!(body)

    case Workbooks.Channels.approve(p["channel"] || "", p["code"] || "") do
      {:ok, peer} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, peer: peer}))

      :not_found ->
        Workbooks.Web.Error.render(conn, :not_found, "no pending pairing code: #{p["code"]}")
    end
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
    # Tenant-scoped (wb-g1yo.9): list only the caller's workbook ids (id-list
    # contract preserved). Public published workbooks are served by PublicWeb.
    ids = Workbooks.ControlPlane.list_workbooks(conn.assigns[:tenant]) |> Enum.map(& &1.id)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(ids))
  end

  get "/api/w/:id/org" do
    # IDOR gate (wb-g1yo.9): don't serve another tenant's workbook source. (Public
    # published content goes through the separate, unauthenticated PublicWeb plane.)
    if Workbooks.ControlPlane.workbook_visible?(conn.params["id"], conn.assigns[:tenant]) do
      org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
      conn |> put_resp_content_type("text/plain; charset=utf-8") |> send_resp(200, org)
    else
      conn |> put_resp_content_type("text/plain; charset=utf-8") |> send_resp(404, "")
    end
  end

  # Server-rendered HTML — the runtime renders the Org (orgize, in the kernel).
  get "/api/w/:id/html" do
    if Workbooks.ControlPlane.workbook_visible?(conn.params["id"], conn.assigns[:tenant]) do
      org = Workbooks.ControlPlane.get_workbook(conn.params["id"]) || ""
      conn |> put_resp_content_type("text/html; charset=utf-8") |> send_resp(200, org)
    else
      conn |> put_resp_content_type("text/html; charset=utf-8") |> send_resp(404, "")
    end
  end

  # --- History + Restore (Phase 1) -------------------------------------------
  # Tenant-scoped per the same wb-g1yo rule as /instances + /api/sessions: the
  # tenant comes from conn.assigns[:tenant] (set by the Auth plug above) and
  # Workbooks.History enforces that the scope (a workbook id) is owned by it.
  # :scope is an OPAQUE id — reject any path/traversal chars (wb-g1yo.10) BEFORE
  # it reaches the engine, so it can never be coerced into a filesystem path.
  get "/api/history/:scope" do
    with :ok <- valid_scope(conn.params["scope"]),
         {:ok, changes} <- Workbooks.History.timeline(conn.params["scope"], conn.assigns[:tenant]) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(changes))
    else
      _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
    end
  end

  get "/api/history/:scope/:id/diff" do
    with :ok <- valid_scope(conn.params["scope"]),
         {:ok, diff} <- Workbooks.History.diff(conn.params["scope"], conn.params["id"], conn.assigns[:tenant]) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(diff))
    else
      _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
    end
  end

  post "/api/history/:scope/restore" do
    {:ok, body, conn} = read_body(conn)
    to = with {:ok, %{"to" => to}} <- Jason.decode(body), do: to, else: (_ -> nil)

    result =
      case valid_scope(conn.params["scope"]) do
        :ok -> Workbooks.History.restore(conn.params["scope"], to, conn.assigns[:tenant])
        _ -> {:error, :not_found}
      end

    case result do
      {:ok, %{} = change} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(change))

      # no-op: working copy already matched the target. A SUCCESS, not an error —
      # answer with a shape the frontend reads as success (not as a Change object).
      {:ok, :unchanged} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"unchanged":true}))

      # cross-tenant / unknown scope / bad change id → not found.
      {:error, reason} when reason in [:not_found, :bad_id] ->
        conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))

      # a genuine restore (commit) failure — never reported as success.
      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(500, ~s({"error":"restore failed"}))
    end
  end

  # Undo (Phase 2): "undo the last change" to a scope — append-only, riding the same
  # Restore primitive, tenant-gated by the same scope-ownership rule. Returns the new
  # Change, or {"nothing":true} when there's nothing earlier to undo to.
  post "/api/history/:scope/undo" do
    result =
      case valid_scope(conn.params["scope"]) do
        :ok -> Workbooks.History.undo(conn.params["scope"], conn.assigns[:tenant])
        _ -> {:error, :not_found}
      end

    case result do
      {:ok, %{} = change} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(change))

      {:ok, :nothing_to_undo} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"nothing":true}))

      {:error, reason} when reason in [:not_found, :bad_id] ->
        conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))

      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(500, ~s({"error":"undo failed"}))
    end
  end

  # --- Shared folders (Phase 3) ----------------------------------------------
  # The one cross-tenant surface. Tenant is the AUTHENTICATED caller (assigns), never
  # a body field. Workbooks.SharedFolder enforces owner-only share/revoke and
  # recipient-only add, fail-closed. Folder/recipient are re-validated in the engine.
  get "/api/shared-folders" do
    t = conn.assigns[:tenant]

    body = %{
      shareable: Workbooks.SharedFolder.shareable(t),
      shared_by: Workbooks.SharedFolder.shared_by(t),
      shared_with: Workbooks.SharedFolder.shared_with(t)
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  post "/api/shared-folders/share" do
    {:ok, raw, conn} = read_body(conn)
    p = case Jason.decode(raw) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end

    mode = if p["mode"] == "draft", do: :draft, else: :read
    t = conn.assigns[:tenant]

    # RBAC (Phase 4): sharing an org folder is an admin+ capability. The tenant wall
    # still confines WHICH folders (SharedFolder), RBAC gates WHO may share them.
    if Workbooks.RBAC.can?(caller_subject(conn), :share, %{tenant: t, level: :folder, id: p["folder"]}) do
      case Workbooks.SharedFolder.share(t, p["folder"], p["recipient"], mode) do
        {:ok, grant} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(grant))
        {:error, :no_such_folder} -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"no such folder"}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"bad request"}))
      end
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, ~s({"error":"forbidden"}))
    end
  end

  # --- Roles (Phase 4 RBAC) --------------------------------------------------
  # Read your tenant's roles (any member); set a member's role (owner-only —
  # :manage_roles). Subject is built from the authenticated identity, never a body.
  get "/api/roles" do
    t = conn.assigns[:tenant]

    if Workbooks.RBAC.can?(caller_subject(conn), :view, %{tenant: t, level: :nexus, id: t}) do
      body = %{roles: Workbooks.ControlPlane.list_roles(t), matrix: rbac_matrix()}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    else
      conn |> put_resp_content_type("application/json") |> send_resp(403, ~s({"error":"forbidden"}))
    end
  end

  post "/api/roles" do
    {:ok, raw, conn} = read_body(conn)
    p = case Jason.decode(raw) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end

    t = conn.assigns[:tenant]
    role = p["role"]
    user = p["user_id"]

    cond do
      # the reserved "*" tenant carries PLATFORM-admin rows — never writable through a
      # tenant-scoped route, regardless of how the tenant string was set.
      t in [nil, "", "*"] ->
        conn |> put_resp_content_type("application/json") |> send_resp(403, ~s({"error":"forbidden"}))

      not Workbooks.RBAC.can?(caller_subject(conn), :manage_roles, %{tenant: t, level: :nexus, id: t}) ->
        conn |> put_resp_content_type("application/json") |> send_resp(403, ~s({"error":"forbidden"}))

      not (is_binary(user) and user != "" and role in ["owner", "admin", "member", "viewer"]) ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"bad request"}))

      true ->
        :ok = Workbooks.ControlPlane.set_role(t, user, role)
        conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
    end
  end

  post "/api/shared-folders/:id/add" do
    case Workbooks.SharedFolder.add_to_workspace(conn.assigns[:tenant], conn.params["id"]) do
      {:ok, r} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(r))
      {:error, :not_found} -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
      _ -> conn |> put_resp_content_type("application/json") |> send_resp(500, ~s({"error":"add failed"}))
    end
  end

  post "/api/shared-folders/:id/revoke" do
    case Workbooks.SharedFolder.revoke(conn.assigns[:tenant], conn.params["id"]) do
      :ok -> conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
      _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
    end
  end

  # --- Drafts (Phase 5) ------------------------------------------------------
  # Try a change safely on the caller's own workspace; Keep or Discard. Operates on
  # the AUTHENTICATED tenant's repo (the :id is the workspace context). RBAC-gated:
  # :view to list/diff, :edit to create/keep/discard. Draft enforces name confinement.
  get "/api/nexuses/:id/drafts" do
    if nexus_can?(conn, :view) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Workbooks.Draft.list(conn.assigns[:tenant])))
    else
      forbidden(conn)
    end
  end

  post "/api/nexuses/:id/drafts" do
    {:ok, raw, conn} = read_body(conn)
    name = with {:ok, %{"name" => n}} <- Jason.decode(raw), do: n, else: (_ -> nil)

    if nexus_can?(conn, :edit) do
      case Workbooks.Draft.create(conn.assigns[:tenant], name) do
        {:ok, d} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(d))
        {:error, :exists} -> conn |> put_resp_content_type("application/json") |> send_resp(409, ~s({"error":"exists"}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"bad request"}))
      end
    else
      forbidden(conn)
    end
  end

  get "/api/nexuses/:id/drafts/:name/diff" do
    if nexus_can?(conn, :view) do
      case Workbooks.Draft.diff(conn.assigns[:tenant], conn.params["name"]) do
        {:ok, changes} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(changes))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
      end
    else
      forbidden(conn)
    end
  end

  post "/api/nexuses/:id/drafts/:name/keep" do
    if nexus_can?(conn, :edit) do
      case Workbooks.Draft.keep(conn.assigns[:tenant], conn.params["name"]) do
        {:ok, r} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(r))
        {:error, :conflict} -> conn |> put_resp_content_type("application/json") |> send_resp(409, ~s({"error":"conflict"}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
      end
    else
      forbidden(conn)
    end
  end

  post "/api/nexuses/:id/drafts/:name/discard" do
    if nexus_can?(conn, :edit) do
      case Workbooks.Draft.discard(conn.assigns[:tenant], conn.params["name"]) do
        :ok -> conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(404, ~s({"error":"not found"}))
      end
    else
      forbidden(conn)
    end
  end

  # --- Backup + app-auth integrations (Phase 6) ------------------------------
  # Backup mirrors the caller's own workspace to a git host. View status with :view;
  # connect/push/disconnect need :manage (admin+). App-auth integration config is
  # read-only here (set by deployment env) — the dashboard surfaces it.
  get "/api/nexuses/:id/backup" do
    if nexus_can?(conn, :view),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Workbooks.Backup.status(conn.assigns[:tenant]))),
      else: forbidden(conn)
  end

  post "/api/nexuses/:id/backup/connect" do
    {:ok, raw, conn} = read_body(conn)
    p = case Jason.decode(raw), do: ({:ok, %{} = m} -> m; _ -> %{})
    opts = [url: p["url"], forge: p["forge"]] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    if nexus_can?(conn, :manage) do
      case Workbooks.Backup.connect(conn.assigns[:tenant], opts) do
        {:ok, r} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(r))
        {:skip, reason} -> conn |> put_resp_content_type("application/json") |> send_resp(409, Jason.encode!(%{error: "unavailable", reason: reason}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"backup failed"}))
      end
    else
      forbidden(conn)
    end
  end

  post "/api/nexuses/:id/backup/push" do
    if nexus_can?(conn, :manage) do
      case Workbooks.Backup.push(conn.assigns[:tenant]) do
        {:ok, r} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(r))
        {:skip, reason} -> conn |> put_resp_content_type("application/json") |> send_resp(409, Jason.encode!(%{error: "unavailable", reason: reason}))
        _ -> conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"backup failed"}))
      end
    else
      forbidden(conn)
    end
  end

  post "/api/nexuses/:id/backup/disconnect" do
    if nexus_can?(conn, :manage),
      do: (Workbooks.Backup.disconnect(conn.assigns[:tenant]); conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok":true}))),
      else: forbidden(conn)
  end

  # The app-auth integration surface (which IdP the tenant's own app uses). Public
  # config only — no secrets; the active provider + claim-map come from deploy env.
  get "/api/auth-integrations" do
    if nexus_can?(conn, :view),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Workbooks.AuthIntegrations.config())),
      else: forbidden(conn)
  end

  # A nexus-level action acts on the caller's own workspace → RBAC resource is their nexus.
  defp nexus_can?(conn, cap) do
    t = conn.assigns[:tenant]
    Workbooks.RBAC.can?(caller_subject(conn), cap, %{tenant: t, level: :nexus, id: t})
  end

  defp forbidden(conn),
    do: conn |> put_resp_content_type("application/json") |> send_resp(403, ~s({"error":"forbidden"}))

  # The RBAC subject for the authenticated caller — role resolved from the registry
  # (never the body). Falls back to tenant-as-user (the single-tenant/desktop identity
  # → owner) when no richer identity is present.
  defp caller_subject(conn) do
    t = conn.assigns[:tenant]
    uid = (conn.assigns[:identity] && conn.assigns[:identity].user_id) || t
    Workbooks.RBAC.subject(t || "", uid || "")
  end

  # ── platform-API helpers (conn-coupled; the rest live in Workbooks.Web.Platform) ──
  defp j(conn, code, data),
    do: conn |> put_resp_content_type("application/json") |> send_resp(code, Jason.encode!(data))

  defp platform_lifecycle(conn, fun) do
    case fun.() do
      {:ok, _} -> j(conn, 200, %{ok: true})
      :ok -> j(conn, 200, %{ok: true})
      {:error, :not_found} -> j(conn, 404, %{error: "not found"})
      {:error, reason} -> j(conn, 422, %{error: reason_str(reason)})
    end
  end

  # Re-verify the bearer to read the user identity claims (sub/name) for /me. The Auth
  # plug already authenticated this request (it only assigned the tenant); this pulls
  # the full claims. JWKS is cached, so the extra verify is cheap. {} if absent/invalid.
  defp me_claims(conn) do
    with [h | _] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- h,
         {:ok, claims} <- Workbooks.OIDC.verify_claims(token) do
      claims
    else
      _ -> %{}
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp send_json(conn, status, payload) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  # Public test/seam surface preserved after the helper split: the workdir
  # confinement rule lives in Workbooks.Web.Helpers but stays reachable here.
  @doc false
  defdelegate confined_workdir(desktop?, tenant, run_id, requested), to: Workbooks.Web.Helpers
end
