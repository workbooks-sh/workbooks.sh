defmodule Workbooks.Harness do
  @moduledoc """
  Posture predicate for the in-wasm HARNESS surface (the SLICE-1/2/3 exec + creds + oauth loopback).

  CLOUD-ENABLE (acp-cloud-enable): the harness surface is now PERMITTED in a multi-tenant hosted runtime when
  explicitly enabled (`WB_HARNESS=1`). The blanket `not Tenancy.multi?()` guard is DROPPED — but ONLY because
  per-tenant isolation is now the real safety, NOT the on/off switch:
    * resident SM instances are pool-capped PER TENANT + globally (`Workbooks.HarnessPool`, gap #1);
    * the grant principal + creds_scope are BOUND to the AUTH-VERIFIED tenant, never a caller-supplied id
      (`HarnessPool.start_session/2`, gap #2) — so the broker's rate/concurrency/budget/revocation key and the
      keychain scope are tenant-true;
    * exec/LLM aggregate budgets are per-tenant (`Workbooks.TenantBudget`, gaps #4/#5);
    * the `:file` creds backend stays REFUSED in multi-tenant (keychain/desktop only — HarnessCreds), and the
      `:desktop` backend HARD-FAILS rather than pooling into a co-located file when no bridge is present.

  This is the single source of truth for "is the harness surface permitted?". It is true when the harness is
  explicitly wanted — `WB_DESKTOP=1` (the packaged desktop), `WB_HARNESS=1` (an explicit opt-in for a single-
  user/dev runtime OR a hosted multi-tenant runtime), OR a multi-tenant hosted posture (`Tenancy.multi?/0`),
  which always wants the per-tenant harness path.

  `Workbooks.Application` gates the `ExecLoopback` child-spec start on `enabled?/0`. The other layers
  (HarnessCreds backend selection, the loopback routes) consult this + the tenancy posture as defense-in-depth.
  """

  @doc """
  True when the in-wasm harness surface (ExecLoopback + creds + oauth) is permitted.

  Permitted iff explicitly requested (`WB_DESKTOP=1` / `WB_HARNESS=1`) OR multi-tenant hosted
  (`Tenancy.multi?` — the per-tenant isolation path is always wanted there). Isolation, not this switch, is
  the safety in multi-tenant (HarnessPool + verified-tenant binding + per-tenant budgets).
  """
  def enabled? do
    requested?() or Workbooks.Tenancy.multi?()
  end

  @doc "True when the harness surface was explicitly requested (desktop or explicit opt-in)."
  def requested? do
    System.get_env("WB_DESKTOP") == "1" or System.get_env("WB_HARNESS") == "1"
  end
end
