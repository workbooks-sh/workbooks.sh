defmodule Workbooks.Harness do
  @moduledoc """
  Posture predicate for the in-wasm HARNESS surface (the SLICE-1/2/3 exec + creds + oauth loopback) — a.k.a.
  the ACP / in-nexus-agent surface.

  EXPERIMENTAL (v2 — NOT production). The entire harness/ACP surface is gated behind `experimental?/0` and is
  OFF by default in a production release. It is RETAINED in the tree (so it can be developed and reasoned
  about) but does not go live in production and is not a shipping/published feature. Turning it on is an
  explicit, deliberate act:

    * production releases (`MIX_ENV=prod`) default it OFF — `enabled?/0` is false even with `WB_DESKTOP=1`,
      `WB_HARNESS=1`, or a multi-tenant posture, UNLESS `WB_ACP_EXPERIMENTAL=1` is also set;
    * dev/test default it ON (so the suites + local experimentation exercise it) — `WB_ACP_EXPERIMENTAL=0`
      force-disables even there;
    * the multi-tenant cloud-enablement path (`Tenancy.multi?/0`) is likewise OFF in production without the
      experimental flag — the per-tenant isolation it relies on (`HarnessPool`, verified-tenant binding,
      `TenantBudget`) stays in code but the surface is not exposed in prod until the v2 review clears.

  When the experimental flag IS set, the surface is permitted when explicitly wanted — `WB_DESKTOP=1` (the
  packaged desktop), `WB_HARNESS=1` (single-user/dev or hosted opt-in), OR a multi-tenant hosted posture
  (`Tenancy.multi?/0`). In multi-tenant, per-tenant isolation — NOT this switch — is the safety:
    * resident SM instances are pool-capped PER TENANT + globally (`Workbooks.HarnessPool`);
    * the grant principal + creds_scope are BOUND to the AUTH-VERIFIED tenant, never a caller-supplied id;
    * exec/LLM aggregate budgets are per-tenant (`Workbooks.TenantBudget`);
    * the `:file` creds backend stays REFUSED in multi-tenant (keychain/desktop only), and the `:desktop`
      backend HARD-FAILS rather than pooling into a co-located file when no bridge is present.

  This is the single source of truth for "is the harness/ACP surface permitted?". `Workbooks.Application`
  gates the `ExecLoopback` child-spec start on `enabled?/0`; the other layers (HarnessCreds backend
  selection, the loopback routes, the `js_engine` host-call import) consult it as defense-in-depth.
  """

  # EXPERIMENTAL default: OFF in a production release, ON in dev/test. `WB_ACP_EXPERIMENTAL=1|0` overrides
  # either way. Baked at compile time (same pattern as Workbooks.Browse.Fetch's @allow_test_loopback).
  @experimental_default Mix.env() != :prod

  @doc """
  True when the in-wasm harness surface (ExecLoopback + creds + oauth + host-call import) is permitted.

  Requires the EXPERIMENTAL gate (`experimental?/0`) AND that the surface is wanted — explicitly requested
  (`WB_DESKTOP=1` / `WB_HARNESS=1`) OR multi-tenant hosted (`Tenancy.multi?`). Without the experimental gate
  the whole surface is OFF, regardless of the other flags — that is the v2/production posture.
  """
  def enabled? do
    experimental?() and (requested?() or Workbooks.Tenancy.multi?())
  end

  @doc """
  True when the ACP / in-wasm-harness surface is experimentally enabled. OFF in production releases unless
  `WB_ACP_EXPERIMENTAL=1`; ON in dev/test unless `WB_ACP_EXPERIMENTAL=0`.
  """
  def experimental? do
    case System.get_env("WB_ACP_EXPERIMENTAL") do
      "1" -> true
      "0" -> false
      _ -> @experimental_default
    end
  end

  @doc "True when the harness surface was explicitly requested (desktop or explicit opt-in)."
  def requested? do
    System.get_env("WB_DESKTOP") == "1" or System.get_env("WB_HARNESS") == "1"
  end
end
