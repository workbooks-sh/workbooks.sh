defmodule Workbooks.Revocation do
  @moduledoc """
  wb-broker MID-FLIGHT REVOCATION — a host can revoke a principal (a tenant, a serve_id, an instance id) so
  its brokered access is denied IMMEDIATELY, even while the guest is running. The brokers consult this on
  every privileged op, so revocation takes effect on the very next call (no need to tear the guest down).

  Public ETS set owned by the long-lived Workbooks.BrokerTables process; `revoke/1` adds, `unrevoke/1`
  removes, `revoked?/1` checks. The "principal" is whatever identity a broker carries (StorageBroker →
  tenant; ServeBroker → serve_id).

  SECURITY (wb self-audit): the table MUST be owned by a never-dying process. The old lazy pattern created it
  from whatever (possibly TRANSIENT) process first touched it; a :named_table dies with its owner, so a
  transient creator's exit would WIPE EVERY REVOCATION — a revoked principal would silently regain access
  (fail-open). Owning it in BrokerTables makes revocation durable for the app lifetime.
  """
  @table :wb_revoked

  def revoke(principal), do: :ets.insert(table(), {principal, true}) && :ok
  def unrevoke(principal), do: :ets.delete(table(), principal) && :ok
  def revoked?(principal), do: :ets.member(table(), principal)

  defp table, do: Workbooks.BrokerTables.ensure(@table, [:named_table, :public, :set])
end
