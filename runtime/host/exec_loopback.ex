defmodule Workbooks.ExecLoopback do
  @moduledoc """
  Brokered-EXEC loopback for the StarlingMonkey eval lane (SLICE 1, wb-b9xv.9).

  The SM eval-host (`Workbooks.JsEngine`) has NO host-import surface beyond `wasi:http` — its only seam
  back to the host is a guest `fetch()`. So a Node `child_process` call on this lane cannot reach a wasm
  import the way the QuickJS/JsDock lane does (Javy.Exec → host_exec). Instead it `fetch`es a FIXED
  internal sentinel URL that the vendored WasiHttpView recognizes and pins to THIS loopback listener
  (the SSRF floor is otherwise bypassed for nothing else — see `store.rs` `wb_resolve_pinned`). The
  request bottoms out in the SAME `Workbooks.ExecBroker.exec/4` the JsDock `host_exec` import calls —
  identical security spine (default-deny, registered-only, depth/concurrency/output caps, structural argv).

  Security across the loopback hop: the SM eval lane carries no per-instance grant, and an unauthenticated
  loopback POST must NOT be able to run arbitrary commands. So exec is GATED ON A PER-RUN NONCE TOKEN:
  `JsEngine.run_node/2` mints one (only when the caller passes `:exec`), records `{principal, commands,
  allow}` here, and embeds it in the boot seam; the shim sends it as the `x-wb-exec` header. An absent or
  unknown token => DEFAULT-DENY (the broker is also called with the recorded grant, never a blanket allow).
  Tokens are single-run scoped and revoked when the run ends.
  """
  use Plug.Router
  require Logger

  alias Workbooks.{ExecBroker, HarnessCreds, OAuthLoopback}

  @grants :wb_exec_loopback_grants
  # the fixed internal sentinel host the Rust WasiHttpView pins to this listener (mirrored in store.rs).
  @sentinel_host "wb-exec.internal"

  @doc "The fixed sentinel hostname a guest fetches; pinned to this loopback by the egress override."
  def sentinel_host, do: @sentinel_host

  @doc """
  Base URL a guest `fetch`es to reach the broker, e.g. `http://wb-exec.internal:<port>`. The port is the
  bound loopback port (discovered from the running listener); the host is the recognized sentinel.
  """
  def sentinel_url, do: "http://#{@sentinel_host}:#{port()}/__wb/exec"

  @doc """
  Base URL a guest `fetch`es to reach the LLM-shaped endpoint (SLICE 2, wb-b9xv.10). Same pinned sentinel
  host as exec — one fixed internal route, token-gated, NOT a NetGuard hole. The endpoint is a minimal
  Claude-Messages-shaped completion seam: a real harness turn fetches it to get the model's next move.
  """
  def llm_url, do: "http://#{@sentinel_host}:#{port()}/__wb/llm"

  @doc "The bound loopback port (started in the supervision tree on 127.0.0.1)."
  def port do
    case :persistent_term.get({__MODULE__, :port}, nil) do
      nil -> raise "ExecLoopback not started"
      p -> p
    end
  end

  @doc """
  Child spec: a Bandit listener bound to 127.0.0.1 on an ephemeral port (0 → OS-assigned), recorded in a
  persistent term for `sentinel_url/0` + the Rust pin. 127.0.0.1-only: the sentinel is never reachable
  off-host, and the SSRF bypass in store.rs targets exactly this address.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_listener, []},
      type: :supervisor
    }
  end

  def start_listener do
    # idempotent: if a listener is already bound + recorded (e.g. started by another caller / a prior test
    # setup), reuse it rather than binding a second listener and overwriting the recorded port.
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: do_start_listener()

      _ ->
        do_start_listener()
    end
  end

  defp do_start_listener do
    port = configured_port()

    case Bandit.start_link(plug: __MODULE__, scheme: :http, ip: {127, 0, 0, 1}, port: port) do
      {:ok, pid} ->
        bound = bound_port(pid, port)
        :persistent_term.put({__MODULE__, :port}, bound)
        :persistent_term.put({__MODULE__, :pid}, pid)
        Logger.info("exec-loopback — brokered SM-lane exec listening on 127.0.0.1:#{bound}")
        {:ok, pid}

      other ->
        other
    end
  end

  # FIX 5 (fixed loopback port / token visibility): default to a RANDOM (OS-assigned, port 0) ephemeral port
  # instead of the predictable fixed 8919, so a local process cannot pre-target the loopback by hard-coded
  # port (it would also need the 24-byte single-run token). The bound port is read back from the listener and
  # published to `sentinel_url/0`; the guest receives the full URL (host + bound port) in its grant seam, and
  # the store.rs sentinel pin honors whatever port the guest fetched (it reads `uri.port_u16()`), so nothing
  # needs a hard-coded port. `WB_EXEC_LOOPBACK_PORT` still pins a fixed port when a deployment requires one.
  defp configured_port do
    case System.get_env("WB_EXEC_LOOPBACK_PORT") do
      nil -> 0
      "" -> 0
      s -> String.to_integer(s)
    end
  end

  defp bound_port(_pid, port) when port != 0, do: port

  defp bound_port(pid, 0) do
    # OS-assigned: ask ThousandIsland for the listener info.
    case ThousandIsland.listener_info(pid) do
      {:ok, {_ip, p}} -> p
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # ── grant registry (per-run nonce → grant) ───────────────────────────────────────────────────

  @doc """
  Mint a single-run token for `grant` (`%{principal, commands, allow}`). Returns the opaque token. The
  shim sends it back as `x-wb-exec`; `revoke/1` removes it when the run ends.
  """
  def mint(grant) when is_map(grant) do
    :ok = assert_principal!(grant)
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ets.insert(grants(), {token, grant})
    token
  end

  # FIX 1 (principal-OPTIONAL minting): an EXEC-capable grant (`allow: true`) MUST carry a non-nil principal —
  # that principal is the only handle the broker has for rate-limit / concurrency-cap / revocation. A grant
  # minted with `allow: true` and a nil principal would, via the loopback, call ExecBroker with principal:nil,
  # which is the reserved HOST-INTERNAL (uncapped, unrevocable) path → a granted harness could fork-bomb the
  # host with no cap and no kill-switch. Refuse it at mint time. Creds-only grants (no `:allow`) are unaffected.
  defp assert_principal!(grant) do
    if Map.get(grant, :allow) == true and not valid_principal?(Map.get(grant, :principal)) do
      raise ArgumentError,
            "exec-capable loopback grant (allow: true) requires a non-nil :principal (tenant/session id) — got " <>
              "#{inspect(Map.get(grant, :principal))}. nil-principal is reserved for trusted host-internal callers."
    end

    :ok
  end

  @doc "Revoke a minted token (run finished)."
  def revoke(token) when is_binary(token), do: :ets.delete(grants(), token)

  defp lookup(token) when is_binary(token) do
    case :ets.lookup(grants(), token) do
      [{^token, grant}] -> {:ok, grant}
      _ -> :error
    end
  end

  defp lookup(_), do: :error

  # FIX 1 (defense-in-depth at the loopback route): an exec-capable grant reaching the broker MUST carry a
  # non-nil principal so the broker's rate/concurrency/revocation guards engage. `mint/1` already refuses to
  # create such a grant, but the route NEVER calls ExecBroker with a nil principal from the loopback — a
  # principal-less exec/llm grant is DENIED here (403). nil-principal stays reserved for trusted HOST-INTERNAL
  # callers (e.g. JsDock direct ExecBroker.exec calls), which never traverse this loopback.
  defp principal_gate(grant) do
    cond do
      Map.get(grant, :allow) != true -> :ok
      valid_principal?(Map.get(grant, :principal)) -> :ok
      true -> {:error, :no_principal}
    end
  end

  defp valid_principal?(p), do: is_binary(p) and p != ""

  # FIX 5 (token visibility): the grant table stays `:public` because mint/revoke run in the JsEngine /
  # HarnessSession processes while lookup runs in Bandit handler processes — none of them is the table's
  # owner (BrokerTables), so `:protected` (owner-only writes) would break mint/revoke from those callers.
  # The residual exposure is mitigated structurally instead: tokens are 24 bytes of CSPRNG entropy, are
  # single-run scoped (revoked when the run/session ends), and now sit behind a RANDOM loopback port (FIX 5),
  # and every exec-capable grant is principal-governed (FIX 1).
  defp grants, do: Workbooks.BrokerTables.ensure(@grants, [:named_table, :public, :set])

  # ── route ────────────────────────────────────────────────────────────────────────────────────

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
  plug(:dispatch)

  # POST /__wb/exec  body {name, argv, stdin}  header x-wb-exec: <token>
  # Bottoms out in ExecBroker.exec/4 with the token's recorded grant — DEFAULT-DENY on unknown token.
  post "/__wb/exec" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    name = conn.body_params["name"]
    argv = conn.body_params["argv"] || []
    stdin = conn.body_params["stdin"] || ""

    with {:ok, grant} <- lookup(token),
         true <- is_binary(name) and is_list(argv),
         :ok <- principal_gate(grant) do
      case ExecBroker.exec(name, Enum.map(argv, &to_string/1), to_string(stdin),
             allow: Map.get(grant, :allow, false),
             commands: Map.get(grant, :commands, :all),
             principal: Map.get(grant, :principal),
             depth: Map.get(grant, :depth, 0) + 1
           ) do
        {:ok, out} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, out)

        {:error, reason} ->
          # 403 so the shim surfaces "denied" rather than a transport error.
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(403, "exec denied: #{inspect(reason)}")
      end
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "exec denied: no/invalid grant token")
    end
  end

  # POST /__wb/llm  body {messages, tools}  header x-wb-exec: <token>
  # An LLM-shaped completion seam (SLICE 2, wb-b9xv.10) for a real headless harness turn. Token-gated like
  # exec (no token => default-deny). DETERMINISTIC mock of the Claude Messages protocol so the THESIS test
  # is hermetic, while the SEAM is fully real (real fetch → HTTP → request/response JSON the harness parses):
  #   - turn 1 (no tool_result yet): return a `tool_use` block (the model decides to call a tool), and
  #   - turn 2 (a tool_result is present): return the final `text` answer that quotes the tool output.
  # This drives the harness's multi-round tool loop end-to-end on the live engine. A real provider can be
  # swapped behind this exact route later (the harness JS is provider-agnostic — it reads stop_reason +
  # content blocks). The route is intentionally minimal; it is NOT the production agent loop.
  post "/__wb/llm" do
    token = get_req_header(conn, "x-wb-exec") |> List.first()
    messages = conn.body_params["messages"] || []

    with {:ok, grant} <- lookup(token),
         :ok <- principal_gate(grant) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(llm_complete(messages)))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "llm denied: no/invalid grant token")
    end
  end

  # ── SLICE 3 (wb-b9xv.7) — the three subscription-auth Dock ops, same pinned sentinel + token gate ─────
  #
  # dock.creds.{get,put} + dock.oauth.loopback. The harness reaches them by `fetch`ing the SAME
  # `wb-exec.internal` sentinel (already pinned to this loopback in store.rs — NO new egress hole, no
  # store.rs change), token-gated like exec/llm (unknown/absent token => default-deny). The per-(user,
  # provider) creds scope is the GRANT's `:creds_scope` — the harness can only touch the user+provider the
  # host granted (BYO + no-pool: one tenant's grant can never read another's blob).

  # POST /__wb/creds/get  body {provider}  header x-wb-exec: <token>
  # -> 200 {"found":true,"blob":"<opaque>"} | 200 {"found":false}. The blob is the harness's own opaque
  # creds bundle (e.g. ~/.claude/.credentials.json contents). The user is the GRANT's scope, never the body
  # (the harness cannot read another user's creds by asking for them).
  post "/__wb/creds/get" do
    with {:ok, grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()),
         {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, conn.body_params["provider"]) do
      case HarnessCreds.get(user, provider) do
        {:ok, blob} ->
          send_json(conn, 200, %{"found" => true, "blob" => blob})

        {:error, :not_found} ->
          send_json(conn, 200, %{"found" => false})
      end
    else
      err -> send_resp(conn, 403, "creds denied: #{inspect(err)}")
    end
  end

  # POST /__wb/creds/put  body {provider, blob}  header x-wb-exec: <token>
  # -> 200 {"ok":true}. Stores the opaque blob for the GRANT's user + the (scoped) provider. We never parse
  # the blob; it is the user's subscription token and goes only to the user's keychain (HarnessCreds).
  post "/__wb/creds/put" do
    with {:ok, grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()),
         {:ok, user} <- creds_user(grant),
         {:ok, provider} <- creds_provider(grant, conn.body_params["provider"]),
         blob when is_binary(blob) <- conn.body_params["blob"],
         :ok <- HarnessCreds.put(user, provider, blob) do
      send_json(conn, 200, %{"ok" => true})
    else
      err -> send_resp(conn, 403, "creds put denied: #{inspect(err)}")
    end
  end

  # POST /__wb/oauth/loopback  body {authorize_base, code_challenge, client_id?, scope?, state?}
  #   header x-wb-exec: <token>
  # -> 200 {"code":"…","redirect_uri":"…"}. Opens the user's browser to the authorize URL (their session,
  # their IP), captures the loopback `?code=`, returns it. PKCE-less: the harness supplies the challenge and
  # keeps the verifier. Desktop-only (loopback + local browser); returns 503 with a clear reason otherwise.
  post "/__wb/oauth/loopback" do
    with {:ok, _grant} <- lookup(get_req_header(conn, "x-wb-exec") |> List.first()) do
      case OAuthLoopback.start(conn.body_params) do
        {:ok, %{code: code, redirect_uri: redirect_uri}} ->
          send_json(conn, 200, %{"code" => code, "redirect_uri" => redirect_uri})

        {:error, :desktop_only} ->
          send_resp(conn, 503, "oauth.loopback unavailable: desktop-only (no local browser/loopback here)")

        {:error, reason} ->
          send_resp(conn, 502, "oauth.loopback failed: #{inspect(reason)}")
      end
    else
      _ -> send_resp(conn, 403, "oauth denied: no/invalid grant token")
    end
  end

  # The user is fixed by the GRANT's creds_scope — NEVER the request body. Absent scope => no creds access.
  defp creds_user(grant) do
    case get_in(grant, [:creds_scope, :user]) || (is_map(grant[:creds_scope]) && grant.creds_scope["user"]) do
      u when is_binary(u) and u != "" -> {:ok, u}
      _ -> {:error, :no_creds_scope}
    end
  end

  # The provider must be on the grant's allowed providers. A single-provider scope ignores the body provider
  # (uses the granted one); a multi-provider scope requires the requested provider to be on the list.
  defp creds_provider(grant, requested) do
    scope = grant[:creds_scope] || %{}
    granted = scope[:provider] || scope["provider"]
    allowed = scope[:providers] || scope["providers"]

    cond do
      is_binary(granted) and granted != "" -> {:ok, granted}
      is_list(allowed) and is_binary(requested) and requested in allowed -> {:ok, requested}
      true -> {:error, :provider_not_in_scope}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Has the conversation already carried a tool_result back? (a user-role message containing a tool_result
  # block). If not, ask for a tool call; if yes, emit the final answer quoting the tool's stdout.
  defp llm_complete(messages) do
    tool_result = find_tool_result(messages)

    if tool_result do
      answer = "The repository has #{String.trim(tool_result)} matching lines."

      %{
        "id" => "msg_wb_llm_final",
        "type" => "message",
        "role" => "assistant",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => answer}]
      }
    else
      %{
        "id" => "msg_wb_llm_tool",
        "type" => "message",
        "role" => "assistant",
        "stop_reason" => "tool_use",
        "content" => [
          %{"type" => "text", "text" => "I'll count the matching lines."},
          %{
            "type" => "tool_use",
            "id" => "toolu_wb_1",
            "name" => "run_command",
            "input" => %{"command" => "grep", "args" => ["needle"], "stdin" => "needle\nhay\nneedle\nstraw\nneedle\n"}
          }
        ]
      }
    end
  end

  # Find a tool_result block anywhere in the message history (a user-role message whose content array
  # carries a {"type":"tool_result", ...}); return its text content, or nil.
  defp find_tool_result(messages) do
    Enum.find_value(messages, fn m ->
      content = (is_map(m) && m["content"]) || nil

      if is_list(content) do
        Enum.find_value(content, fn b ->
          if is_map(b) and b["type"] == "tool_result" do
            case b["content"] do
              t when is_binary(t) -> t
              [%{"text" => t} | _] -> t
              _ -> nil
            end
          end
        end)
      end
    end)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
