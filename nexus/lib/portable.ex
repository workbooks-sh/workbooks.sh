defmodule Nexus.Portable do
  @moduledoc """
  Cross-nexus portability (epic wb-kodp, wb-744n) — a user's contributions aggregated across nexuses.

  Portability is mostly INHERENT: a `did:key` is self-certifying, so a contribution signed on one nexus
  verifies on any other with no shared state (`Nexus.Attest`/`Nexus.Keyring`), and a person's identity
  (their did:key) is the same everywhere. The one capability this adds is the MERGE: take signed
  contribution records gathered from several nexuses and produce the verified, deduped global view.

  A record is `%{commit: <hash>, att: <attestation>, nexus: <id>}`. `aggregate/2`:
    * keeps only self-consistent records (the attestation verifies against its OWN did);
    * optionally keeps only records signed by a given set of `:dids` (the user's keys → their profile);
    * dedups by commit hash (the same commit pushed to N nexuses is ONE contribution).
  """

  alias Nexus.Attest

  @doc "Merge signed contribution records across nexuses → verified, optionally user-scoped, deduped by commit."
  @spec aggregate([map()], keyword()) :: [map()]
  def aggregate(records, opts \\ []) when is_list(records) do
    dids = opts[:dids]

    records
    |> Enum.filter(&verified?/1)
    |> filter_dids(dids)
    |> Enum.uniq_by(& &1.commit)
  end

  defp verified?(%{att: %{did: did} = att}), do: Attest.verify(att, did)
  defp verified?(_), do: false

  defp filter_dids(records, nil), do: records
  defp filter_dids(records, dids), do: Enum.filter(records, fn %{att: att} -> att.did in dids end)
end
