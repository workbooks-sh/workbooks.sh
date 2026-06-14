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
end
