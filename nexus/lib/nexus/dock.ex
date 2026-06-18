defmodule Nexus.Dock do
  @moduledoc """
  The ONE capability registry: capability → {WIT interface, grant, impl}. Replaces the old
  policy layer entirely — caps + WIT grants ARE the policy. wasmex marshals the calls.

  STATUS: **port** from `runtime/host/dock.ex` — built & tested. (Old policy.ex does NOT carry over.)
  """
  def capabilities, do: raise("port from runtime/host/dock.ex")
end
