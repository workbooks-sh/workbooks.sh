defmodule Nexus.Application do
  @moduledoc """
  OTP application root for the nexus release.

  `Nexus.Deploy.Machine` boots the microVM with `/app/bin/nexus eval "Application.ensure_all_started(
  :nexus) … Process.sleep(:infinity)"` (and the release's `bin/nexus start`), so `:nexus` must START
  and keep a live tree. Beyond the pure pipelines (Literate → Compile → Sandbox → Weave), in a
  **serving** context (a release, or `WB_SERVE`/`WB_DESKTOP` set) it also brings up `Nexus.Server`
  (the HTTP tier, incl. `/health`) and publishes the desktop discovery file — so a deployed/local
  nexus actually answers on its port. `mix test` is NOT a serving context (no port binding).
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Load runtime config from the deployment's `deploy` block (the .work source of truth) into
    # :persistent_term BEFORE the Gate reads its concurrency limit. No env vars for tunable config.
    Nexus.Config.boot()
    # The server HTML cache (rendered workbooks). Create it here so the LONG-LIVED application process
    # owns it. Otherwise the first REQUEST process to render creates+owns it, and ETS deletes the table
    # when that request ends — so the next concurrent insert throws ArgumentError (intermittent 500s
    # under load / right after a cold start). :public so any request process can read/write.
    if :ets.whereis(:nexus_server_cache) == :undefined do
      :ets.new(:nexus_server_cache, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    # Per-tenant rate-limit counters (Dock LLM/fetch caps, wb-9g6s) — same long-lived-owner rationale.
    Nexus.RateLimit.init()
    # Washy operability metrics (in-process wasm runs) — lock-free :counters + reason histograms, owned
    # by the long-lived app process. Lazily inits anyway, but seed it here so the table owner is stable.
    Nexus.Washy.Metrics.ensure()
    # Warm the agent-shell caches (shell wasm + coreutils registry) off the boot path, so the first
    # concurrent burst of agent runs doesn't each redundantly decode the 9.6MB registry (thundering herd).
    Task.start(fn -> Nexus.Shell.warm() end)
    # A serving nexus persists to durable SQLite on the mounted volume (Litestream ships it off-box;
    # see Nexus.Litestream). Dev/test set their own adapter explicitly, so only adopt SQLite when the
    # adapter is still the in-memory default — never clobber a deliberate choice.
    configure_store()
    # Register the selected `:search` provider behind the Nexus.Browse seam. Default = keyless
    # metasearch (pure-BEAM, local/dev); `deploy search="brave"` swaps in the keyed cloud API.
    register_search_provider()
    # A user-workbook nexus runs in the AUTH MODE its `deploy do auth=… end` block declares, so a
    # workbook's identity/tenant behavior is IDENTICAL local (vfkit) and cloud (Fly) — the keystone of
    # deploy parity. Default (no block / auth="trusted") = Nexus.Auth.None (open, single-tenant).
    configure_runtime_auth()
    # In the control-plane role, gate /api/platform behind our own native session / PAT
    # (Nexus.Auth.Cloud) — every caller carries a real org identity (fail-closed; see Nexus.ControlPlane).
    # This OVERRIDES the deploy-block auth above for our dashboard role only.
    Nexus.ControlPlane.configure_auth()
    # Empty by default; Constellation's local-inference lanes opt in via `config :nexus, Nexus.Constellation, enabled: true`.
    ether = if Nexus.Constellation.enabled?(), do: Nexus.Constellation.children(), else: []
    # Nexus.Wasm.Gate bounds concurrent wasm OS processes per lane (compile-concurrency /
    # render-concurrency) so a burst can't fork-bomb wasmtime into an OOM — backpressure instead.
    # The reactive layer: the event bus (subscriber Registry + Task.Supervisor) + the generic built-in
    # effects (emit/run/notify). Consumers register more effects on top (e.g. the cloud `log` effect).
    Nexus.Effects.install_builtins()
    # The `sweep` effect — collapses drawered (`-#`) hash notes into the drawer. Our opinion,
    # registered on top of the generic engine (not a builtin in the open standard).
    Nexus.HashNote.Sweep.install()

    # Fail closed on a deployed release with no strong shared session secret (red-team wb-nz88): an
    # ephemeral per-boot key invalidates sessions across instances/restarts and nudges the control plane
    # toward its public-default fallback. A real release (RELEASE_NAME set) must have WB_SESSION_SECRET;
    # desktop/dev (WB_SERVE/WB_DESKTOP, single instance) keep the dev_key fallback.
    if System.get_env("RELEASE_NAME") not in [nil, ""] and not Nexus.Auth.Session.strong_secret?() do
      raise "WB_SESSION_SECRET must be set (>= 16 bytes) on a deployed release — refusing to boot with an ephemeral session key (wb-nz88)"
    end

    children =
      # Nexus.Broker FIRST — the credential trust boundary holds the KEK + Fly token; everything that
      # decrypts the secret store or calls Fly is a thin client of it, so it must be up before them.
      [Nexus.Broker, Nexus.Telemetry, Nexus.Autopoet.Lease, Nexus.Analytics, Nexus.ControlPlane.Store, Nexus.ControlPlane.Token, Nexus.Auth.Token] ++
        Nexus.Writer.Lock.child_specs() ++
        Nexus.Events.child_specs() ++ Nexus.Scheduler.child_specs() ++ Nexus.Worker.child_specs() ++
        Nexus.Wasm.Gate.child_specs() ++ Nexus.Cache.child_specs() ++ Nexus.Cell.child_specs() ++ ether ++ server_children()
    result = Supervisor.start_link(children, strategy: :one_for_one, name: Nexus.Supervisor)

    # On a real serving nexus, lock down the credential broker: the KEK + Fly token are now captured in
    # Nexus.Broker's state, so scrub them from the shared OS process env — a compile-time RCE or tenant
    # `.work` can no longer `System.get_env` them (red-team wb-qmp8 / wb-7zsr). Skipped under `mix test`
    # (serve? == false) so tests can set the key dynamically.
    if serve?(), do: Nexus.Broker.lockdown()

    # Once the server is up, publish the desktop discovery file (no-op unless WB_DESKTOP_DIR is set).
    if serve?(), do: Nexus.Desktop.write_discovery(port())
    result
  end

  # Serve when we're a deployed runtime (a release sets RELEASE_NAME) or explicitly told to
  # (WB_SERVE / WB_DESKTOP — the desktop injects WB_DESKTOP=1). `mix test` matches none → no listener.
  defp serve? do
    System.get_env("RELEASE_NAME") != nil or
      System.get_env("WB_SERVE") in ~w(1 true) or
      System.get_env("WB_DESKTOP") in ~w(1 true)
  end

  defp server_children do
    if serve?(), do: [{Nexus.Server, root: root(), port: port()}], else: []
  end

  # Durable SQLite on the volume for a serving nexus, unless an adapter was chosen deliberately
  # (dev per-workbook DB / tests / an explicit cloud adapter). Litestream (if S3 secrets are
  # injected) replicates this file off-box; without secrets it's still durable on the volume.
  defp configure_store do
    if serve?() and Application.get_env(:nexus, :store_adapter, Nexus.Store.Ets) == Nexus.Store.Ets do
      adapter =
        case Nexus.Config.store_adapter() do
          :postgres_unimplemented ->
            require Logger
            Logger.error(~s([deploy] database="postgres" declared but no Postgres adapter yet — using SQLite))
            Nexus.Store.Sqlite

          mod ->
            mod
        end

      Application.put_env(:nexus, :store_adapter, adapter)
    end
  end

  # The deploy-block auth mode → the request-auth adapter (Nexus.Config.auth_adapter). Only in a
  # serving context; `mix test`/pure pipelines keep the default. The CP role overrides this next.
  defp configure_runtime_auth do
    if serve?(), do: Application.put_env(:nexus, :auth, Nexus.Config.auth_adapter())
  end

  @doc """
  Re-read the deploy block and re-apply the deploy MODE (store + auth adapter). Called by
  `Nexus.Server.remount` after a `git push` lands a workbook, so its declared `auth=…`/`database=…`
  takes effect without a reboot — keeping a freshly-pushed local workbook in the same mode it'd run in
  cloud. The CP-role auth override is preserved.
  """
  def apply_deploy_mode do
    Nexus.Config.boot()
    configure_store()
    configure_runtime_auth()
    Nexus.ControlPlane.configure_auth()
    :ok
  end

  # PORT + WB_DATA are deploy injection (the orchestrator sets the port + the volume mount), like
  # WB_DATA elsewhere — infrastructure, not authored config.
  # Select + register the configured `:search` provider (keyless metasearch is the safe default).
  defp register_search_provider do
    mod =
      case Nexus.Config.search() do
        "brave" -> Nexus.Browse.Search.Brave
        "metasearch" -> Nexus.Browse.Search.Metasearch
        _ -> Nexus.Browse.Search.Metasearch
      end

    Nexus.Browse.register(mod)
  end

  defp port, do: String.to_integer(System.get_env("PORT") || "4000")
  defp root, do: System.get_env("WB_DATA") || File.cwd!()
end
