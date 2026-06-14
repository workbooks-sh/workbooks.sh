defmodule Workbooks.HarnessCreds do
  @moduledoc """
  Per-(user, provider) credential store for the in-wasm harness — SLICE 3 (wb-b9xv.7), the host half of
  the `dock.creds.{get,put}` ops.

  WHAT THIS IS — the harness (Claude Code et al. running on the StarlingMonkey lane) owns its OWN OAuth
  state machine and writes its credential bundle to a file path (e.g. `~/.claude/.credentials.json`). On
  the SM lane that fs write/read is INTERCEPTED and mapped onto `dock.creds.put`/`dock.creds.get` instead
  of the KV-VFS, so the harness's own store hits the OS keychain. We store an OPAQUE blob: never parse it,
  never decode it, never send it anywhere except the harness's own egress fetch (path c / NetGuard).

  DESKTOP-FIRST + BYO + NO-POOL (the ToS guarantee):
    * scope is per-(user, provider) — the keychain account is the provider, the value is the user's own
      subscription-token blob. One user's blob is NEVER reachable by another (the store key embeds the
      user id; per-provider service names also reduce repeat macOS keychain prompts — risk #6).
    * the blob is the USER'S subscription token. It lives ONLY in the user's trust domain (their keychain),
      flows ONLY to the user's own provider over the user's own IP. It is NEVER pooled, proxied, or shared
      across tenants, and is NEVER registered as one of OUR platform secrets (that is the SEPARATE
      `secret_broker.ex` API-key path — subscription tokens never touch it).

  TWO PROVIDERS behind ONE seam (the canon desktop/web/mobile capability-provider shape):
    * `:file` (this module's default + the runtime-canonical store) — an owner-only (0600) JSON file,
      key `"<service>\\x01<account>"` exactly mirroring desktop `keychain.rs` `kc_set/kc_get/kc_delete`
      (the desktop dropped the prompting OS keychain for a 0600 file under FileVault; wb-2s09). Service =
      `sh.workbooks.harness.<provider>` (parallel to `SVC_CONN` "sh.workbooks.conn"), account = the user id.
      This is the piece PROVEN here (round-trips through the loopback in the SLICE-3 test).
    * `:desktop` (designed, wired on a built desktop) — forwards get/put to the Tauri side's
      `harness_creds_get`/`harness_creds_put` commands, which own the real OS keychain entry. See
      `desktop/src-tauri/src/keychain.rs` (`harness_*`). The runtime can't read the host keychain itself
      (esp. containerized), so on a packaged desktop the Tauri layer is authoritative; the file store is
      the runtime-local fallback (and the CI/test substrate).

  Provider is chosen by `WB_HARNESS_CREDS=desktop|file` (default `file`).
  """
  require Logger

  # Parallel to SVC_CONN "sh.workbooks.conn" / KC_SERVICE "sh.workbooks.identity" in keychain.rs — one
  # service per provider so a per-provider keychain grant doesn't re-prompt for every other provider (risk #6).
  @service_prefix "sh.workbooks.harness."

  @doc "The keychain service name for a provider (e.g. `sh.workbooks.harness.claude`)."
  def service(provider) when is_binary(provider), do: @service_prefix <> provider

  @doc """
  Read the opaque creds blob for `{user, provider}`. Returns `{:ok, blob}` | `{:error, :not_found}`.
  The value is whatever the harness last `put` — we never parse it.
  """
  def get(user, provider) when is_binary(user) and is_binary(provider) do
    case backend() do
      :desktop -> desktop_get(user, provider)
      :file -> file_get(user, provider)
    end
  end

  @doc """
  Store the opaque creds blob for `{user, provider}` (overwrites any prior). `blob` is a binary; we store
  it verbatim. Returns `:ok` | `{:error, reason}`.
  """
  def put(user, provider, blob)
      when is_binary(user) and is_binary(provider) and is_binary(blob) do
    case backend() do
      :desktop -> desktop_put(user, provider, blob)
      :file -> file_put(user, provider, blob)
    end
  end

  @doc "Delete the blob for `{user, provider}` (sign-out). `:ok` regardless of prior presence."
  def delete(user, provider) when is_binary(user) and is_binary(provider) do
    case backend() do
      :desktop -> desktop_delete(user, provider)
      :file -> file_delete(user, provider)
    end
  end

  # ── provider selection ─────────────────────────────────────────────────────────────────────────

  defp backend do
    case System.get_env("WB_HARNESS_CREDS") do
      "desktop" -> :desktop
      _ -> :file
    end
  end

  # ── :file provider — mirrors keychain.rs kc_set/kc_get/kc_delete exactly ─────────────────────────

  # store key "<service>\x01<account>" — byte-for-byte the desktop `sk(service, account)` shape.
  defp sk(service, account), do: service <> <<1>> <> account

  defp store_path do
    dir = System.get_env("WB_HARNESS_CREDS_DIR") || Path.join(System.tmp_dir!(), "wb-harness-creds")
    File.mkdir_p!(dir)
    Path.join(dir, "harness-creds.json")
  end

  defp store_load do
    with {:ok, body} <- File.read(store_path()),
         {:ok, m} when is_map(m) <- Jason.decode(body) do
      m
    else
      _ -> %{}
    end
  end

  defp store_save(map) when is_map(map) do
    path = store_path()
    File.write!(path, Jason.encode!(map))
    # owner-only (0600), like keychain.rs secrets_save — the blob is a live subscription token.
    _ = File.chmod(path, 0o600)
    :ok
  end

  defp file_get(user, provider) do
    case Map.get(store_load(), sk(service(provider), user)) do
      blob when is_binary(blob) -> {:ok, blob}
      _ -> {:error, :not_found}
    end
  end

  defp file_put(user, provider, blob) do
    store_load()
    |> Map.put(sk(service(provider), user), blob)
    |> store_save()
  end

  defp file_delete(user, provider) do
    store_load()
    |> Map.delete(sk(service(provider), user))
    |> store_save()
  end

  # ── :desktop provider — forwards to the Tauri keychain commands (built-desktop only) ─────────────
  #
  # DESIGNED, wired on a packaged desktop. The runtime cannot read the host OS keychain itself (and is
  # often containerized), so the Tauri layer owns the keychain entry and exposes get/put over the local
  # desktop control bridge. The runtime issues a request and awaits the reply. Implemented as a clear
  # design stub here because the Tauri/OS layer can't be built/run in this runtime worktree (per the slice
  # brief); a maintainer on a built desktop wires `Workbooks.DesktopBridge.call/2` to the
  # `harness_creds_get`/`harness_creds_put` Tauri commands (the keychain.rs `harness_*` fns).

  defp desktop_get(user, provider), do: desktop_call("harness_creds_get", %{user: user, provider: provider})
  defp desktop_put(user, provider, blob), do: desktop_call("harness_creds_put", %{user: user, provider: provider, blob: blob})
  defp desktop_delete(user, provider), do: desktop_call("harness_creds_delete", %{user: user, provider: provider})

  defp desktop_call(cmd, args) do
    if Code.ensure_loaded?(Workbooks.DesktopBridge) and
         function_exported?(Workbooks.DesktopBridge, :call, 2) do
      apply(Workbooks.DesktopBridge, :call, [cmd, args])
    else
      Logger.warning("HarnessCreds :desktop backend selected but no DesktopBridge — falling back to :file")
      case cmd do
        "harness_creds_get" -> file_get(args.user, args.provider)
        "harness_creds_put" -> file_put(args.user, args.provider, args.blob)
        "harness_creds_delete" -> file_delete(args.user, args.provider)
      end
    end
  end
end
