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
end
