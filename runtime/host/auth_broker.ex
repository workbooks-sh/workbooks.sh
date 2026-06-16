defmodule Workbooks.AuthBroker do
  @moduledoc """
  The desktop sign-in broker. The native app can't hold a WorkOS client secret, so
  it runs a loopback+PKCE flow against THIS server, which holds the secret and drives
  hosted AuthKit:

      GET  /v1/auth/authorize  — app opens this in a browser (carries its loopback
                                 redirect_uri + PKCE challenge) → 302 to AuthKit
      GET  /v1/auth/callback   — AuthKit returns here → we authenticate the code,
                                 mint a one-time broker code → 302 back to loopback
      POST /v1/auth/exchange   — app posts {code, code_verifier} → the session bearer

  The bearer we hand back is the WorkOS access token (an RS256 JWT this runtime
  already verifies via its JWKS), so the platform accepts it with no extra trust.

  Flow state (state ids, one-time codes) lives in this GenServer, expiring in minutes.
  It is deliberately NOT in the durable secrets store: a control-plane restart mid
  sign-in just means the user clicks sign-in again — there's nothing worth persisting.

  Security floors: `redirect_uri` MUST be loopback (no open redirector); codes are
  one-time + short-TTL; the exchange enforces PKCE S256 (the app proves it began the
  flow). Inert unless `Workbooks.WorkOS.configured?/0` (a WorkOS key is set).
  """
  use GenServer
  require Logger

  @state_ttl 600
  @code_ttl 300
  @purge_every 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Build the AuthKit authorize URL for a loopback sign-in. `{:ok, url}` | `{:error, _}`."
  def begin_authorize(redirect_uri, code_challenge) do
    cond do
      not Workbooks.WorkOS.configured?() -> {:error, :not_configured}
      not loopback?(redirect_uri) -> {:error, :bad_redirect}
      not valid_challenge?(code_challenge) -> {:error, :bad_challenge}
      true -> GenServer.call(__MODULE__, {:begin, redirect_uri, code_challenge})
    end
  end

  @doc "Handle the AuthKit callback. `{:ok, loopback_redirect_with_code}` | `{:error, _}`."
  def complete_callback(workos_code, state) when is_binary(workos_code) and is_binary(state),
    do: GenServer.call(__MODULE__, {:callback, workos_code, state}, 20_000)

  def complete_callback(_, _), do: {:error, :bad_request}

  @doc "Redeem a one-time broker code for the session. `{:ok, stored_session_map}` | `{:error, _}`."
  def exchange(code, code_verifier) when is_binary(code) and is_binary(code_verifier),
    do: GenServer.call(__MODULE__, {:exchange, code, code_verifier})

  def exchange(_, _), do: {:error, :bad_request}

  # ── server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :timer.send_interval(@purge_every, :purge)
    {:ok, %{flows: %{}}}
  end

  @impl true
  def handle_call({:begin, redirect_uri, challenge}, _from, s) do
    state = token()
    flows = put(s.flows, state, %{redirect_uri: redirect_uri, challenge: challenge}, @state_ttl)
    {:reply, {:ok, Workbooks.WorkOS.authorize_url(callback_url(), state)}, %{s | flows: flows}}
  end

  def handle_call({:callback, workos_code, state}, _from, s) do
    case take(s.flows, state) do
      {%{redirect_uri: redirect_uri, challenge: challenge}, flows} ->
        case Workbooks.WorkOS.authenticate(workos_code) do
          {:ok, session} ->
            code = token()
            flows = put(flows, code, %{session: session, challenge: challenge}, @code_ttl)
            {:reply, {:ok, append_code(redirect_uri, code)}, %{s | flows: flows}}

          {:error, reason} ->
            Logger.warning("auth broker: authenticate failed: #{inspect(reason)}")
            {:reply, {:error, :authenticate_failed}, %{s | flows: flows}}
        end

      :error ->
        {:reply, {:error, :unknown_state}, s}
    end
  end

  def handle_call({:exchange, code, verifier}, _from, s) do
    case take(s.flows, code) do
      {%{session: session, challenge: challenge}, flows} ->
        if pkce_ok?(verifier, challenge) do
          {:reply, {:ok, stored_session(session)}, %{s | flows: flows}}
        else
          {:reply, {:error, :pkce_mismatch}, %{s | flows: flows}}
        end

      :error ->
        {:reply, {:error, :unknown_code}, s}
    end
  end

  @impl true
  def handle_info(:purge, s) do
    now = now()
    {:noreply, %{s | flows: :maps.filter(fn _, {_, exp} -> exp > now end, s.flows)}}
  end

  # ── flow store (id → {payload, expires}) ──────────────────────────────────────

  defp put(flows, id, payload, ttl), do: Map.put(flows, id, {payload, now() + ttl})

  defp take(flows, id) do
    case Map.pop(flows, id) do
      {{payload, exp}, rest} when is_integer(exp) ->
        if exp > now(), do: {payload, rest}, else: :error

      _ ->
        :error
    end
  end

  # ── session shaping ────────────────────────────────────────────────────────

  # The desktop's StoredSession (see desktop/src-tauri/src/network.rs).
  defp stored_session(%{access_token: tok, user: user} = session) do
    %{
      bearer: tok,
      expires_at: session.expires_at || 0,
      sub: user["id"] || "",
      email: user["email"] || "",
      email_verified: user["email_verified"] || false,
      organization_id: session.organization_id,
      display_name: display_name(user),
      picture_url: user["profile_picture_url"]
    }
  end

  defp display_name(user) do
    [user["first_name"], user["last_name"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      name -> name
    end
  end

  # ── guards / helpers ───────────────────────────────────────────────────────

  # Only a loopback redirect — the broker must never bounce a code to an arbitrary host.
  defp loopback?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: h} when h in ["127.0.0.1", "localhost", "::1"] -> true
      _ -> false
    end
  end

  defp loopback?(_), do: false

  defp valid_challenge?(c), do: is_binary(c) and byte_size(c) in 16..256 and c =~ ~r/^[A-Za-z0-9_-]+$/

  defp pkce_ok?(verifier, challenge) do
    expected = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(expected, challenge)
  end

  defp append_code(redirect_uri, code) do
    sep = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
    redirect_uri <> sep <> "code=" <> code
  end

  defp callback_url do
    base = System.get_env("WB_BROKER_BASE") || "https://wb-nexus-cp.fly.dev"
    String.trim_trailing(base, "/") <> "/v1/auth/callback"
  end

  defp token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: System.system_time(:second)
end
