defmodule Workbooks.JsHarnessAuthTest do
  @moduledoc """
  SLICE 3 gate (wb-b9xv.7) — the three subscription-auth Dock ops the in-wasm harness needs, proven on
  the live engine where buildable, and on the host seam directly where the desktop OS layer can't run here.

  DESKTOP-FIRST + BYO + NO-POOL: the harness's subscription token stays in the user's trust domain
  (keychain + their browser + their IP); it is never pooled/proxied. The host supplies only three
  primitives the harness would otherwise get from native syscalls:

    (a) dock.creds.{get,put} — per-(user, provider) opaque-blob store backed by `Workbooks.HarnessCreds`
        (file-backed mirror of desktop keychain.rs on the runtime; OS keychain on a built desktop). PROVEN
        here: a put then a get round-trips the exact opaque bytes through the loopback + the keychain seam,
        and the user is fixed by the GRANT's creds_scope — never the request — so one grant can't read
        another user's blob.
    (b) dock.oauth.loopback — browser-open + loopback callback, PKCE-less (the host returns only the code;
        the harness keeps the verifier). Desktop-only (local browser + loopback socket); in this worktree
        it returns `{:error, :desktop_only}` with the exact JSON contract a built desktop fills in.
    (c) egress — NO new primitive: the harness's token-exchange + bearer'd API fetch go through the
        existing guest fetch -> NetGuard with a per-host allow-list. (Covered by the NetGuard suite.)

  The creds + scope tests run WITHOUT the SM eval-host (they drive the host seam directly), so they are
  hermetic. The end-to-end SM test is `:build`-tagged.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{HarnessCreds, ExecLoopback, JsEngine}

  setup_all do
    # The CI/test substrate is a SINGLE-USER DESKTOP posture: enable the harness surface so the
    # ExecLoopback listener + the HarnessCreds :file backend are permitted (FIX 2 / FIX 3). Start the
    # loopback listener once for the host-route tests (the app does NOT start it in test env now that it's
    # posture-gated). Force single-tenant so the file backend is allowed.
    prev_harness = System.get_env("WB_HARNESS")
    prev_mode = System.get_env("WB_TENANCY_MODE")
    System.put_env("WB_HARNESS", "1")
    System.delete_env("WB_TENANCY_MODE")

    # Start the listener UNLINKED so it survives this ephemeral test process across modules (Bandit.start_link
    # links to its caller; a linked listener would die with this setup_all and leave a stale recorded port).
    {:ok, _} =
      Task.start(fn ->
        Workbooks.ExecLoopback.start_listener()
        Process.sleep(:infinity)
      end)

    Enum.reduce_while(1..100, :ok, fn _, _ ->
      if is_integer(:persistent_term.get({Workbooks.ExecLoopback, :port}, nil)),
        do: {:halt, :ok},
        else: (Process.sleep(10); {:cont, :ok})
    end)

    on_exit(fn ->
      if prev_harness, do: System.put_env("WB_HARNESS", prev_harness), else: System.delete_env("WB_HARNESS")
      if prev_mode, do: System.put_env("WB_TENANCY_MODE", prev_mode)
    end)

    :ok
  end

  setup do
    # isolate the file-backed creds store per test run (owner-only 0600, like keychain.rs).
    dir = Path.join(System.tmp_dir!(), "wb-harness-creds-test-#{System.unique_integer([:positive])}")
    prev = System.get_env("WB_HARNESS_CREDS_DIR")
    System.put_env("WB_HARNESS_CREDS_DIR", dir)
    System.delete_env("WB_HARNESS_CREDS")

    on_exit(fn ->
      if prev, do: System.put_env("WB_HARNESS_CREDS_DIR", prev), else: System.delete_env("WB_HARNESS_CREDS_DIR")
      File.rm_rf(dir)
    end)

    :ok
  end

  # ── (a) HarnessCreds keychain seam — the runtime-side store, PROVEN ──────────────────────────────

  test "creds store round-trips an OPAQUE blob, per-(user, provider), and is owner-only" do
    blob = ~s({"access_token":"sk-ant-oat-USERSECRET","refresh_token":"rt-USERSECRET","expires_at":9999999999})

    assert {:error, :not_found} = HarnessCreds.get("user-A", "claude")
    assert :ok = HarnessCreds.put("user-A", "claude", blob)
    # stored verbatim — never parsed/decoded.
    assert {:ok, ^blob} = HarnessCreds.get("user-A", "claude")

    # per-(user, provider) ISOLATION (no-pool): another user / another provider sees nothing.
    assert {:error, :not_found} = HarnessCreds.get("user-B", "claude")
    assert {:error, :not_found} = HarnessCreds.get("user-A", "openai")

    # per-provider service name parallels keychain.rs SVC_CONN.
    assert HarnessCreds.service("claude") == "sh.workbooks.harness.claude"
  end

  # ── (a) the loopback route enforces the grant's creds_scope (BYO / no-pool over the wire) ────────

  test "creds routes fix the user from the grant, default-deny without scope" do
    token_scoped = ExecLoopback.mint(%{creds_scope: %{user: "user-A", provider: "claude"}})
    token_noscope = ExecLoopback.mint(%{commands: :all})

    on_exit(fn -> ExecLoopback.revoke(token_scoped); ExecLoopback.revoke(token_noscope) end)

    base = "http://127.0.0.1:#{ExecLoopback.port()}"
    blob = ~s({"access_token":"sk-ant-SCOPED"})

    # PUT then GET with the scoped token — the user is the GRANT's, the body carries only the provider.
    assert {:ok, %{status: 200}} = post(base <> "/__wb/creds/put", token_scoped, %{provider: "claude", blob: blob})

    assert {:ok, %{status: 200, body: got}} =
             post(base <> "/__wb/creds/get", token_scoped, %{provider: "claude"})

    assert Jason.decode!(got) == %{"found" => true, "blob" => blob}
    # the blob landed under the GRANTED user, provably (read it back through the store directly).
    assert {:ok, ^blob} = HarnessCreds.get("user-A", "claude")

    # NO creds_scope on the grant => default-deny (the harness cannot name a user to read).
    assert {:ok, %{status: 403}} = post(base <> "/__wb/creds/get", token_noscope, %{provider: "claude"})

    # single-provider scope PINS provider=claude — a body provider is ignored, so it can never read
    # a different provider's slot (it reads claude's, which is what was stored).
    assert {:ok, %{status: 200, body: pinned}} =
             post(base <> "/__wb/creds/get", token_scoped, %{provider: "openai"})

    assert Jason.decode!(pinned) == %{"found" => true, "blob" => blob}

    # unknown token => default-deny.
    assert {:ok, %{status: 403}} = post(base <> "/__wb/creds/get", "bogus-token", %{provider: "claude"})
  end

  # ── (b) oauth.loopback contract — desktop-only here, exact JSON shape for a built desktop ────────

  test "oauth.loopback validates params and is desktop-only in this worktree" do
    # missing required params => error before any browser/socket.
    assert {:error, {:missing_param, "authorize_base"}} =
             Workbooks.OAuthLoopback.start(%{"code_challenge" => "abc"})

    assert {:error, {:missing_param, "code_challenge"}} =
             Workbooks.OAuthLoopback.start(%{"authorize_base" => "https://claude.ai/oauth/authorize"})

    # valid params, no desktop bridge in this worktree => desktop_only (the route maps this to HTTP 503).
    assert {:error, :desktop_only} =
             Workbooks.OAuthLoopback.start(%{
               "authorize_base" => "https://claude.ai/oauth/authorize",
               "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
             })

    # the route surfaces it as 503 (not a transport error), so the harness can fall back to device-code.
    token = ExecLoopback.mint(%{creds_scope: %{user: "user-A", provider: "claude"}})
    on_exit(fn -> ExecLoopback.revoke(token) end)
    base = "http://127.0.0.1:#{ExecLoopback.port()}"

    assert {:ok, %{status: 503}} =
             post(base <> "/__wb/oauth/loopback", token, %{
               authorize_base: "https://claude.ai/oauth/authorize",
               code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
             })
  end

  # ── (a) END-TO-END on the SM lane: the harness shim drives creds.put/get over fetch ──────────────

  @tag :build
  @tag timeout: 60_000
  test "harness dock.creds.{put,get} round-trips through the SM shim + loopback + keychain" do
    if not match?({:ok, _}, JsEngine.build_host()) do
      IO.puts("\n[skip] SM eval-host not built")
    else
      src = ~S"""
      const dock = require('dock-auth');
      const blob = JSON.stringify({ access_token: "sk-ant-SM-LANE", refresh_token: "rt" });
      await dock.creds.put("claude", blob);
      const got = await dock.creds.get("claude");
      console.log(got === blob ? "ROUNDTRIP-OK" : ("MISMATCH:" + got));
      """

      {:ok, %{stdout: out}} =
        JsEngine.run_node(src,
          exec: [allow: true, commands: :all, principal: "test-tenant", creds_scope: %{user: "sm-user", provider: "claude"}]
        )

      assert out =~ "ROUNDTRIP-OK"
      # and it actually landed in the keychain seam under the granted user.
      assert {:ok, blob} = HarnessCreds.get("sm-user", "claude")
      assert blob =~ "sk-ant-SM-LANE"
    end
  end

  # ── tiny HTTP helper — a PLAIN :httpc POST to the loopback listener ──────────────────────────────
  #
  # NOT NetGuard.request: that path enforces the SSRF floor and DENIES 127.0.0.1 on purpose (the harness
  # only reaches this listener through the store.rs `wb-exec.internal` pin, which is the single sanctioned
  # loopback bypass). For the host-route unit test we hit the bound listener directly with :httpc, exactly
  # as the pinned guest fetch arrives at it. Returns `{:ok, %{status:, body:}}`.
  defp post(url, token, body) do
    _ = Application.ensure_all_started(:inets)
    headers = [{~c"x-wb-exec", String.to_charlist(token)}]
    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [{:timeout, 5_000}], []) do
      {:ok, {{_v, status, _r}, _h, resp_body}} ->
        {:ok, %{status: status, body: IO.iodata_to_binary(resp_body)}}

      other ->
        other
    end
  end
end
