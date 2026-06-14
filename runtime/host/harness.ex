defmodule Workbooks.Harness do
  @moduledoc """
  Posture predicate for the in-wasm HARNESS surface (the SLICE-1/2/3 exec + creds + oauth loopback).

  FIX 2 (POSTURE GAP — surface ALWAYS-ON): the `Workbooks.ExecLoopback` listener (and the whole exec +
  subscription-creds + oauth-loopback surface that bottoms out in it) was started UNCONDITIONALLY in
  `Workbooks.Application`. That surface is a DESKTOP-FIRST primitive — a 127.0.0.1 loopback the local
  harness fetches, the user's own keychain, the user's own browser. It has NO place in a multi-tenant
  hosted runtime: there, tenants share a process and the loopback's token table is :public, so an
  always-on exec broker is an unnecessary blast-radius.

  This is the single source of truth for "is the harness surface permitted?". It is true ONLY when:
    * the harness is explicitly wanted — `WB_DESKTOP=1` (the packaged desktop) OR `WB_HARNESS=1`
      (an explicit opt-in for a single-user/dev runtime), AND
    * the runtime is NOT a multi-tenant hosted posture (`Workbooks.Tenancy.multi?/0`).

  `Workbooks.Application` gates the `ExecLoopback` child-spec start on `enabled?/0`, so in a hosted /
  multi-tenant runtime the loopback is never started → the exec + creds + oauth surface is OFF entirely.
  The other layers (HarnessCreds :file backend, the loopback routes) consult this too as defense-in-depth.
  """

  @doc """
  True when the in-wasm harness surface (ExecLoopback + creds + oauth) is permitted.

  Permitted iff (`WB_DESKTOP=1` or `WB_HARNESS=1`) AND NOT multi-tenant hosted.
  """
  def enabled? do
    requested?() and not Workbooks.Tenancy.multi?()
  end

  @doc "True when the harness surface was explicitly requested (desktop or explicit opt-in)."
  def requested? do
    System.get_env("WB_DESKTOP") == "1" or System.get_env("WB_HARNESS") == "1"
  end
end
