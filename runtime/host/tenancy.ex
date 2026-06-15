defmodule Workbooks.Tenancy do
  @moduledoc """
  Tenancy posture (`WB_TENANCY_MODE`, set by a deployment.org's `TENANCY_MODE`):

    * `:single` — the deployment serves ONE tenant. Auth may still identify a user,
      but everyone shares the one workspace; the `x-tenant` dev header + anonymous
      fallback are fine (a box you run for yourself / a single-org product).
    * `:multi` — per-tenant ISOLATION is enforced. A request MUST carry a verified
      identity (a JWT whose org IS the tenant); the anonymous `dev` fallback and a
      caller-supplied `x-tenant` header are REJECTED — a tenant can't be spoofed.

  This is the one place the mode is read; `Workbooks.Auth` consults it to decide
  whether to allow the unauthenticated path. Defaults to `:single`.
  """

  @doc "The configured tenancy mode (`:single` | `:multi`; default `:single`)."
  def mode do
    case System.get_env("WB_TENANCY_MODE", "single") do
      "multi" -> :multi
      _ -> :single
    end
  end

  @doc "True when per-tenant isolation must be enforced (multi-tenant)."
  def multi?, do: mode() == :multi

  @doc """
  True when a public bearer GATE is configured (`WB_PUBLIC_BEARER`) — the single
  source of the "locked" posture, so `Workbooks.Auth` and this module agree.
  """
  def locked?, do: (System.get_env("WB_PUBLIC_BEARER") || "") != ""

  @doc """
  True when this process is a HOSTED/cloud deployment rather than a laptop/desktop:
  an explicit `WB_CONTROL_PLANE=1` / `WB_CLOUD=1`, or running on Fly (`FLY_APP_NAME`).
  Used only to scope the boot safety assert — desktop/dev never trip it.
  """
  def cloud_role? do
    System.get_env("WB_CONTROL_PLANE") == "1" or
      System.get_env("WB_CLOUD") == "1" or
      (System.get_env("FLY_APP_NAME") || "") != ""
  end

  @doc """
  The dangerous posture (wb-2kt9): a hosted instance that is NEITHER locked NOR
  multi-tenant honors a caller-supplied `x-tenant` header, so a request could scope
  to ANY tenant. Safe iff it isn't a cloud role, OR it's locked, OR it's multi-tenant.
  """
  def safe_posture?, do: not cloud_role?() or locked?() or multi?()

  @doc """
  Fail-fast at boot: a cloud-role instance MUST be locked or multi-tenant. Refuses to
  start an unsafe hosted posture rather than silently trusting the `x-tenant` header.
  No-op on desktop/dev/tests (not a cloud role). Returns `:ok` or raises.
  """
  def assert_safe_posture! do
    if safe_posture?() do
      assert_multitenant_isolation!()
      :ok
    else
      raise """
      Unsafe tenancy posture for a hosted deployment (wb-2kt9).
      This is a cloud role (WB_CONTROL_PLANE / WB_CLOUD / FLY_APP_NAME) but is neither
      locked (WB_PUBLIC_BEARER) nor multi-tenant (WB_TENANCY_MODE=multi) — so a
      caller-supplied `x-tenant` header could scope to any tenant.
      Set WB_TENANCY_MODE=multi (isolation) or WB_PUBLIC_BEARER (lock) before boot.
      """
    end
  end

  @doc """
  Fail-fast (acp-cloud-enable gaps #6/#7): a MULTI-TENANT instance must have the per-tenant isolation
  substrate configured before boot:
    * a DURABLE per-deployment var store — `WB_VARS` must NOT be the default `:memory:` (a fresh in-process
      SQLite would lose every tenant's vars/keys on restart and isn't shared across nodes);
    * a keychain/desktop creds backend — `WB_HARNESS_CREDS=desktop` (never the co-located `:file` store) so
      one tenant's subscription tokens are never pooled.
  No-op outside multi-tenant. Returns `:ok` or raises.
  """
  def assert_multitenant_isolation! do
    if multi?() do
      vars = System.get_env("WB_VARS")

      if vars in [nil, "", ":memory:"] do
        raise """
        Multi-tenant runtime requires a DURABLE per-deployment var store (acp-cloud-enable gap #6).
        WB_VARS is unset/`:memory:` — a fresh in-process SQLite loses every tenant's vars + per-tenant
        keys on restart and is not shared across nodes. Set WB_VARS to a durable file path before boot.
        """
      end

      if System.get_env("WB_HARNESS_CREDS") != "desktop" do
        raise """
        Multi-tenant runtime requires a keychain/desktop creds backend (acp-cloud-enable gap #7).
        WB_HARNESS_CREDS must be `desktop` — the co-located `:file` store pools every tenant's subscription
        tokens into one shared file and is forbidden in multi-tenant. Set WB_HARNESS_CREDS=desktop.
        """
      end
    end

    :ok
  end
end
