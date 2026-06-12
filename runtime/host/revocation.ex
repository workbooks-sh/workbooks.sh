defmodule Workbooks.Revocation do
  @moduledoc """
  wb-broker MID-FLIGHT REVOCATION — a host can revoke a principal (a tenant, a serve_id, an instance id) so
  its brokered access is denied IMMEDIATELY, even while the guest is running. The brokers consult this on
  every privileged op, so revocation takes effect on the very next call (no need to tear the guest down).

  Lazy public ETS set; `revoke/1` adds, `unrevoke/1` removes, `revoked?/1` checks. The "principal" is
  whatever identity a broker carries (StorageBroker → tenant; ServeBroker → serve_id).
  """
  @table :wb_revoked

  def revoke(principal), do: :ets.insert(table(), {principal, true}) && :ok
  def unrevoke(principal), do: :ets.delete(table(), principal) && :ok
  def revoked?(principal), do: :ets.member(table(), principal)

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

        @table

      _ ->
        @table
    end
  end
end
