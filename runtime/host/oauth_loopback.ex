defmodule Workbooks.OAuthLoopback do
  @moduledoc """
  `dock.oauth.loopback` — the browser-open + loopback-callback half of an RFC-8252 native-app OAuth flow,
  provider-agnostic and PKCE-LESS. SLICE 3 (wb-b9xv.7), the host half of the OAuth op.

  DERIVED from the desktop `network.rs` `workos_sign_in` (the generalization the map calls for), with two
  deliberate REMOVALS so this is a reusable primitive, not a WorkOS-specific flow:

    1. PKCE MOVED OUT OF THE HOST. `workos_sign_in` called `pkce()` to make the verifier+S256 challenge.
       Here the HARNESS generates them in StarlingMonkey WebCrypto (`crypto.subtle.digest` + `importKey` +
       `sign` are present on SM — empirically), so the VERIFIER NEVER CROSSES THE MEMBRANE. The host op
       receives only the harness-supplied `code_challenge` (+ the authorize base) and returns the `code`;
       the harness keeps the verifier and does the token exchange itself (path c, NetGuard fetch).

    2. NO TOKEN EXCHANGE. `workos_sign_in` then POSTed `/v1/auth/exchange` and parsed a `StoredSession`.
       That is deleted: the host op ENDS at returning `{code, redirect_uri}`. Token exchange + refresh
       live in the harness (its own `fetch` through NetGuard), so the bearer is direct user→provider and
       this host op stays provider-neutral.

  So `dock.oauth.loopback` == the loopback-server + browser-open half of `workos_sign_in`, minus PKCE,
  minus exchange.

  WHAT THE HOST DOES (verbatim from workos_sign_in, generalized):
    a. `tiny_http::Server::http("127.0.0.1:0")` — bind an ephemeral loopback port.
    b. build `redirect_uri = http://127.0.0.1:<port>/cb` and substitute it + the harness's challenge into
       the harness-supplied `authorize_base` (response_type=code, code_challenge_method=S256).
    c. `open::that(authorize)` — open the USER'S OWN BROWSER (their session, their IP — the BYO/no-pool core).
    d. block on `server.recv()` for the single `?code=` redirect, respond "you can close this tab", and
       return `{code, redirect_uri}` to the harness.

  DESKTOP-FIRST. This op assumes a LOCAL browser + a loopback socket — i.e. a packaged desktop. The
  tiny_http server + `open::that` live in desktop Rust (`network.rs` `harness_oauth_loopback`, the
  generalized command). The runtime invokes it over the desktop bridge and relays `{code, redirect_uri}`
  to the harness. The cloud-nexus device-code / paste-back fork is DEFERRED (wb-b9xv.17) — desktop-only is
  the unambiguously safe ship (the subscription token never leaves the user's machine).

  In this runtime worktree the desktop Rust can't be built/run, so `start/1` returns `{:error,
  :desktop_only}` unless a `Workbooks.DesktopBridge` is wired — the contract + JSON shape are exact so a
  maintainer on a built desktop only has to point the bridge at the Tauri command.
  """
  require Logger

  @doc """
  Run the loopback authorize step. `params`:
    * `:authorize_base` — the provider's authorize endpoint (e.g.
      `https://claude.ai/oauth/authorize` / `https://console.anthropic.com/...`). REQUIRED.
    * `:code_challenge` — the harness's S256 challenge (base64url, no padding). REQUIRED. The host NEVER
      sees the verifier.
    * `:client_id`, `:scope`, `:state` — optional, forwarded into the authorize URL verbatim.

  Returns `{:ok, %{code: code, redirect_uri: redirect_uri}}` | `{:error, reason}`. The harness then
  exchanges `code` (+ its private verifier) at the provider's token endpoint over its own NetGuard fetch.
  """
  # FIX 4 (oauth.loopback arbitrary URL): `authorize_base` is fully harness-controlled and is handed to the
  # desktop `open::that`. WITHOUT validation a harness could open ANY URL in the user's browser (phishing /
  # local-app deep-link). Require an https scheme AND a host on the provider allow-list. The list is
  # configurable via `config :workbooks, :oauth_authorize_hosts`; defaults to the known Claude/OpenAI hosts.
  @default_authorize_hosts ~w(
    claude.ai
    anthropic.com
    console.anthropic.com
    openai.com
    chatgpt.com
    auth.openai.com
  )

  def start(params) when is_map(params) do
    with {:ok, base} <- require_str(params, "authorize_base"),
         {:ok, challenge} <- require_str(params, "code_challenge"),
         :ok <- validate_authorize_base(base) do
      args = %{
        authorize_base: base,
        code_challenge: challenge,
        client_id: params["client_id"],
        scope: params["scope"],
        state: params["state"]
      }

      if bridge_available?() do
        apply(Workbooks.DesktopBridge, :call, ["harness_oauth_loopback", args])
      else
        Logger.info("oauth.loopback: no desktop bridge in this worktree (#{inspect(base)}) — desktop-only op")
        {:error, :desktop_only}
      end
    end
  end

  @doc "The configured allow-list of authorize hosts (overridable via app config)."
  def authorize_hosts do
    Application.get_env(:workbooks, :oauth_authorize_hosts, @default_authorize_hosts)
  end

  # Reject a non-https or off-allow-list authorize_base before any browser open. A host matches if it is
  # exactly an allow-list entry or a subdomain of one (e.g. `console.anthropic.com` ⊂ `anthropic.com`).
  defp validate_authorize_base(base) do
    uri = URI.parse(base)

    cond do
      uri.scheme != "https" ->
        {:error, {:invalid_authorize_base, :https_required}}

      is_nil(uri.host) or uri.host == "" ->
        {:error, {:invalid_authorize_base, :no_host}}

      not host_allowed?(uri.host) ->
        {:error, {:invalid_authorize_base, {:host_not_allowed, uri.host}}}

      true ->
        :ok
    end
  end

  defp host_allowed?(host) do
    host = String.downcase(host)

    Enum.any?(authorize_hosts(), fn allowed ->
      allowed = String.downcase(allowed)
      host == allowed or String.ends_with?(host, "." <> allowed)
    end)
  end

  defp require_str(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_param, key}}
    end
  end

  defp bridge_available? do
    Code.ensure_loaded?(Workbooks.DesktopBridge) and
      function_exported?(Workbooks.DesktopBridge, :call, 2)
  end
end
