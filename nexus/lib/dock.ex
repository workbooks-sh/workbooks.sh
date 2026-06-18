defmodule Nexus.Dock do
  @moduledoc """
  §3 — the single capability **registry**: one source of truth for what host
  capabilities exist, the WIT interface each projects, and the grant that unlocks it.

  This is step 1 of collapsing the four parallel Dock seams (Instance WIT imports,
  host_broker JSON envelope, RustDock/JsDock core ABI) into one. Those seams become
  *transports* that project from this registry (later steps). Today it is already the
  source `Nexus.Wit` reads to generate a unit's `import`s — so §2's generated
  worlds and the Dock are the same surface, by construction rather than by coincidence.
  """

  # The registry is the UNION of two capability vocabularies the runtime speaks:
  #
  #  • sandbox caps (`sandbox?: true`) — net/kv/secrets/fs/exec — the per-unit grants
  #    an author writes; each projects a self-contained WIT `interface` so a generated
  #    component package validates standalone. Read by `Nexus.Wit`.
  #  • runtime caps (`import:`) — vfs/commands/llm/browse/parallel — the live WIT-typed
  #    Instance Dock seam (`instance/imports.ex`), each projecting one host import name.
  #    Locked by the characterization snapshot; the seam will reproject from here.
  @registry %{
    "net" => %{interface: "host-net", wit: "interface host-net {\n  fetch: func(url: string) -> string;\n}", sandbox?: true, dock_fns: ~w(fetch get post)},
    "kv" => %{interface: "host-kv", wit: "interface host-kv {\n  get: func(key: string) -> string;\n  put: func(key: string, val: string);\n}", sandbox?: true, dock_fns: ~w(kv put read)},
    "secrets" => %{interface: "host-secrets", wit: "interface host-secrets {\n  read: func(key: string) -> string;\n}", sandbox?: true, dock_fns: ~w(secret secrets)},
    "fs" => %{interface: "host-fs", wit: "interface host-fs {\n  read: func(path: string) -> string;\n  write: func(path: string, data: string);\n}", sandbox?: true, dock_fns: ~w(fs file)},
    "exec" => %{interface: "host-exec", wit: "interface host-exec {\n  run: func(cmd: string, args: list<string>) -> string;\n}", sandbox?: true, dock_fns: ~w(exec run)},
    "vfs" => %{import: "vfs-query", sig: "func(sql: string) -> string"},
    "commands" => %{import: "run-command", sig: "func(command: string, input: string, args: list<string>) -> string"},
    "llm" => %{import: "llm-complete", sig: "func(prompt: string) -> string"},
    "browse" => %{import: "browse-fetch", sig: "func(url: string) -> string"},
    "parallel" => %{import: "run-command-many", sig: "func(command: string, inputs: string) -> string"}
  }

  # the always-present imports / the entrypoint export that bookend the engine world
  @engine_always "import session-info: func() -> string;"
  @engine_export "export run: func(input: string) -> string;"

  # The RustDock core-module ABI transport: each capability projects one or more
  # `env.host_*` ptr/len imports. Recorded here so the Dock registry is the union of
  # ALL seam surfaces (WIT-typed Instance + core-ABI Rust); the seam reprojects from
  # this later. Locked against rust_dock.ex by the characterization snapshot.
  @rust_ambient ~w(host_now host_log)
  @rust_abi %{
    "egress" => ~w(host_http_get host_http_get_many),
    "exec" => ~w(host_exec host_parallel_map),
    "encode" => ~w(host_ffmpeg_encode),
    "udp" => ~w(host_udp),
    "tls" => ~w(host_tls),
    "tcp" => ~w(host_tcp),
    "queue" => ~w(host_publish host_poll),
    "secrets" => ~w(host_sign),
    "kv" => ~w(host_kv_put host_kv_get),
    "vfs" => ~w(host_vfs_write host_vfs_read)
  }

  # spec grant → the live runtime capability it maps onto (best-effort; the obvious
  # correspondences only). Used when the generated-WIT grant vocabulary meets the
  # runtime seam; secrets/fs have no runtime-cap analogue yet.
  @grant_aliases %{"net" => "browse", "kv" => "vfs", "exec" => "commands", "llm" => "llm", "browse" => "browse"}

  @doc "Every capability name in the registry (both vocabularies)."
  def capabilities, do: Map.keys(@registry)

  @doc """
  Host functions a unit can call by name → `{wit_signature, impl}`. The signature is the WIT the
  unit's import is typed with (so we don't derive it from the unit's lowered `extern` decl); the
  impl is what runs on the host. Both scalar (`now`) and string (`log`) — string caps lift cleanly
  in the reactor shape (see docs/STRING-CAP-ABI.md).
  """
  def host_fns do
    %{
      "now" => {"func() -> s64", fn -> System.os_time(:second) end},
      # `emit`, not `log` — `log` collides with libm's math `log` (rust links libstd, which defines
      # it, so the import is never left to rewrite). Cap names must be single-word + collision-free.
      "emit" => {"func(msg: string)", fn msg -> require(Logger) && Logger.info(["[unit] ", msg]); nil end},
      # a real string-RETURNING cap: an in-memory kv (proves the canonical-ABI return path).
      "store" => {"func(key: string, val: string)", fn k, v -> :persistent_term.put({:nexus_kv, k}, v); nil end},
      "load" => {"func(key: string) -> string", fn k -> :persistent_term.get({:nexus_kv, k}, "") end},
      # net: an HTTP GET (TLS-verified, via the shared client). TODO: this is UNBROKERED — a real
      # deployment must route `fetch` through an SSRF-safe allowlist (the runtime's host broker).
      "fetch" => {"func(url: string) -> string", fn url ->
         case Nexus.Compilers.Shared.http_get(url) do
           {:ok, body} -> body
           _ -> ""
         end
       end},
      # llm: a chat completion (OpenRouter). Returns "" if no key is configured.
      "complete" => {"func(prompt: string) -> string", &__MODULE__.llm_complete/1}
    }
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
  (`%{"name" => {:fn, impl}}`). A component only invokes the imports it declares; extras are
  ignored, so we offer the full set.
  """
  def impls, do: Map.new(host_fns(), fn {n, {_sig, f}} -> {n, {:fn, f}} end)

  @doc "The per-unit sandbox-enforced capabilities (granted by an author, audited by the weave)."
  def sandbox_capabilities, do: for({c, %{sandbox?: true}} <- @registry, do: c)

  @doc "The live runtime seam capabilities (the WIT-typed Instance Dock imports)."
  def runtime_capabilities, do: for({c, m} <- @registry, Map.has_key?(m, :import), do: c)

  # reverse index: a `Dock.<fn>` a unit calls → the sandbox capability it exercises
  @dock_fn_index (for {cap, %{dock_fns: fns}} <- @registry, f <- fns, into: %{}, do: {f, cap})

  @doc "The sandbox capability a `Dock.<fn>` call exercises (for the weave caps audit), or nil."
  def cap_for_dock_fn(fn_name), do: @dock_fn_index[to_string(fn_name)]

  @doc "Is `cap` a known capability?"
  def capability?(cap), do: Map.has_key?(@registry, cap)

  @doc "Is `cap` a sandbox cap that projects a generated WIT interface?"
  def sandbox_capability?(cap) do
    get_in(@registry, [cap, :sandbox?]) == true
  end

  @doc "The WIT interface name a sandbox capability imports (e.g. \"net\" → \"host-net\")."
  def interface_name(cap), do: get_in(@registry, [cap, :interface])

  @doc "The self-contained WIT interface definition for a sandbox capability."
  def interface_wit(cap), do: get_in(@registry, [cap, :wit])

  @doc "The host import name a runtime capability projects (e.g. \"llm\" → \"llm-complete\")."
  def import_name(cap), do: get_in(@registry, [cap, :import])

  @doc "The runtime capability a spec grant maps onto, if any."
  def runtime_cap_for(grant), do: @grant_aliases[grant]

  @doc """
  The WIT import a granted capability projects — the one vocabulary both the generated
  world (`Nexus.Wit`) and the runtime seam speak. A sandbox cap projects its
  `host-*` interface; a runtime cap projects its typed import; an aliased spec grant
  projects the runtime import it maps onto. `nil` if the grant has no projection.
  """
  def grant_import(grant) do
    cond do
      sandbox_capability?(grant) -> interface_name(grant)
      import_name(grant) -> import_name(grant)
      rc = runtime_cap_for(grant) -> import_name(rc)
      true -> nil
    end
  end

  @doc "The always-present RustDock ambient core-ABI imports."
  def rust_ambient, do: @rust_ambient

  @doc "The RustDock `env.host_*` core-ABI imports a capability projects."
  def rust_abi(cap), do: Map.get(@rust_abi, cap, [])

  @doc "Every RustDock core-ABI import name the registry knows (ambient + all caps)."
  def rust_abi_names do
    (@rust_ambient ++ (@rust_abi |> Map.values() |> List.flatten())) |> Enum.uniq() |> Enum.sort()
  end

  @doc "The raw registry map."
  def registry, do: @registry

  @doc """
  Generate the `workbooks:engine` Dock world from the registry — the typed surface a
  Workbook Instance runs against (session-info + every runtime capability's import +
  the `run` entrypoint). This replaces the hand-written `wit/engine.wit`: the world
  falls out of the registry, so it can't drift from the seam that projects it.
  """
  def engine_world do
    imports =
      for {_cap, %{import: name, sig: sig}} <- @registry,
          do: "import #{name}: #{sig};",
          into: []

    body = [@engine_always | Enum.sort(imports)] ++ [@engine_export]

    "package workbooks:engine;\n\nworld engine {\n" <>
      Enum.map_join(body, "\n", &("  " <> &1)) <> "\n}\n"
  end
end
