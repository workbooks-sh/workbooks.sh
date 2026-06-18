defmodule Nexus.Dock do
  @moduledoc """
  The runtime capability **membrane** — the live host implementations a sandboxed component runs
  against (SSRF-brokered `fetch`, `llm_complete`, the kv store, the wasmex import map). The capability
  *catalog* (what exists, the WIT each projects, the grant vocabulary) lives in `WorkCore.Capabilities`
  so the `.work` toolchain (`WorkCore.Wit`) and this seam read one source of truth; the catalog queries
  below delegate there.
  """

  alias WorkCore.Capabilities

  @doc """
  Host functions a unit can call by name → `{wit_signature, impl}`. The signature is the WIT the
  unit's import is typed with; the impl is what runs on the host.
  """
  def host_fns do
    %{
      "now" => {"func() -> s64", fn -> System.os_time(:second) end},
      # `emit`, not `log` — `log` collides with libm's math `log`.
      "emit" => {"func(msg: string)", fn msg -> require(Logger) && Logger.info(["[unit] ", msg]); nil end},
      # a real string-RETURNING cap: an in-memory kv (proves the canonical-ABI return path).
      "store" => {"func(key: string, val: string)", fn k, v -> :persistent_term.put({:nexus_kv, k}, v); nil end},
      "load" => {"func(key: string) -> string", fn k -> :persistent_term.get({:nexus_kv, k}, "") end},
      # net: a TLS-verified HTTP GET, SSRF-brokered (see fetch/1).
      "fetch" => {"func(url: string) -> string", &__MODULE__.fetch/1},
      # llm: a chat completion (OpenRouter). Returns "" if no key is configured.
      "complete" => {"func(prompt: string) -> string", &__MODULE__.llm_complete/1}
    }
  end

  @doc """
  SSRF-brokered HTTP GET for the `fetch` cap. ALWAYS blocks loopback/private/link-local hosts and
  non-http(s) schemes. If `NEXUS_NET_ALLOW` is set the URL's host must be on it. `""` on block/failure.
  """
  def fetch(url) do
    if net_allowed?(url) do
      case Nexus.Compilers.Shared.http_get(url) do
        {:ok, body} -> body
        _ -> ""
      end
    else
      ""
    end
  end

  @doc """
  The SSRF gate, exposed so any host-side fetch escalation (e.g. the curl-impersonate fallback in
  `Nexus.Compilers.Shared.http_get/1`) re-guards itself before egress — never an unguarded path.
  """
  def net_allowed?(url) do
    uri = URI.parse(url)
    host = uri.host || ""

    cond do
      uri.scheme not in ["http", "https"] -> false
      private_host?(host) -> false
      allowlist() == [] -> true
      true -> host in allowlist()
    end
  end

  defp allowlist do
    case System.get_env("NEXUS_NET_ALLOW") do
      v when v in [nil, ""] -> []
      v -> v |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  # Loopback / private / link-local — the SSRF danger zone a unit must never reach.
  defp private_host?(h) do
    h in ["localhost", "127.0.0.1", "0.0.0.0", "::1", ""] or
      String.starts_with?(h, "127.") or String.starts_with?(h, "10.") or
      String.starts_with?(h, "192.168.") or String.starts_with?(h, "169.254.") or
      String.match?(h, ~r/^172\.(1[6-9]|2\d|3[01])\./)
  end

  @doc false
  @llm_model "openai/gpt-4o-mini"
  def llm_complete(prompt) do
    key = System.get_env("OPENROUTER_API_KEY")

    if key do
      :inets.start()
      :ssl.start()
      body = Jason.encode!(%{model: @llm_model, messages: [%{role: "user", content: prompt}]})

      ssl_opts = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      req = {~c"https://openrouter.ai/api/v1/chat/completions", [{~c"authorization", ~c"Bearer #{key}"}], ~c"application/json", body}

      case :httpc.request(:post, req, [ssl: ssl_opts, timeout: 60_000], body_format: :binary) do
        {:ok, {{_, 200, _}, _h, resp}} ->
          case Jason.decode(resp) do
            {:ok, %{"choices" => [%{"message" => %{"content" => c}} | _]}} -> c || ""
            _ -> ""
          end

        _ ->
          ""
      end
    else
      ""
    end
  end

  @doc "Whether a host fn returns a string (→ the unit's component needs a cabi_realloc export)."
  def returns_string?(name), do: (host_fn_wit(name) || "") |> String.contains?("-> string")

  @doc "The WIT signature for a host fn the unit imports, or nil if it isn't a known cap."
  def host_fn_wit(name), do: with({sig, _impl} <- host_fns()[name], do: sig)

  @doc """
  Host implementations the Dock supplies to a sandboxed component, as the wasmex import map
  (`%{"name" => {:fn, impl}}`).
  """
  def impls, do: Map.new(host_fns(), fn {n, {_sig, f}} -> {n, {:fn, f}} end)

  # ── capability catalog — the source of truth is WorkCore.Capabilities; delegate so existing
  #    Nexus.Dock.<catalog> callers (and the runtime seam) keep one vocabulary. ───────────────────
  defdelegate capabilities(), to: Capabilities
  defdelegate sandbox_capabilities(), to: Capabilities
  defdelegate runtime_capabilities(), to: Capabilities
  defdelegate cap_for_dock_fn(fn_name), to: Capabilities
  defdelegate capability?(cap), to: Capabilities
  defdelegate sandbox_capability?(cap), to: Capabilities
  defdelegate interface_name(cap), to: Capabilities
  defdelegate interface_wit(cap), to: Capabilities
  defdelegate import_name(cap), to: Capabilities
  defdelegate runtime_cap_for(grant), to: Capabilities
  defdelegate grant_import(grant), to: Capabilities
  defdelegate rust_ambient(), to: Capabilities
  defdelegate rust_abi(cap), to: Capabilities
  defdelegate rust_abi_names(), to: Capabilities
  defdelegate registry(), to: Capabilities
  defdelegate engine_world(), to: Capabilities
end
