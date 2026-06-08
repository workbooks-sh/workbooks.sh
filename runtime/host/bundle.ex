defmodule Workbooks.Bundle do
  @moduledoc """
  The Workbook egress format (wb-11ck.29): one portable `.wbundle` (a zip) holding
  the Workbook HTML, its SQLite VFS (all named volumes), and a manifest. Hand
  someone one file and they have the complete session — and because it's a plain
  zip, any tool can open it (not a BEAM-only term). ship → restore round-trips it;
  archiving is just writing the blob to cold storage / R2.
  """

  @doc ~S|Pack a parts map (%{"name" => binary}) into one zip blob.|
  def pack(parts) when is_map(parts) do
    files = Enum.map(parts, fn {k, v} -> {String.to_charlist(k), v} end)
    {:ok, {_name, zip}} = :zip.create(~c"workbook.wbundle", files, [:memory])
    zip
  end

  @doc "Unpack a Bundle blob back to its parts map."
  def unpack(blob) when is_binary(blob) do
    {:ok, files} = :zip.extract(blob, [:memory])
    Map.new(files, fn {name, content} -> {List.to_string(name), content} end)
  end

  @doc """
  Ship a Workbook for egress: bundle its HTML + VFS (the single SQLite file
  carrying every named volume) + a manifest. Returns the `.wbundle` blob.

  Sealed-bundle ("rzip", wb-v3w): pass `gated: ["secret.html", ...]` to SEAL those
  entries. A sealed entry is AES-256-GCM ciphertext; its content key is escrowed at
  the runtime (`Workbooks.Bundle.Escrow`) and the manifest carries only a
  `key_refs` reference (`path → %{key_id, algo}`), NEVER the key. Public entries
  stay plaintext. The runtime releases a key only after `Workbooks.Access.enforce`
  passes (`POST /rcp/key/:key_id`), so the gated bytes are noise to anyone who has
  the bundle but not a posture-approved release.
  """
  def ship(id, html, vfs_bytes, opts \\ []) when is_binary(vfs_bytes) do
    # Privacy by default: a shared bundle carries the working tree, NOT the
    # session that made it — agent memory + tmp are stripped unless the owner
    # explicitly opts in. One boundary (`Workbooks.Private`) for every egress.
    vfs_bytes = if opts[:include_private], do: vfs_bytes, else: Workbooks.VFS.public_only(vfs_bytes)

    {html, signed} =
      case opts[:tenant] do
        nil -> {html, false}
        t -> {Workbooks.Manifest.sign(html, t, [%{"type" => "c2pa.action.published", "actor" => Workbooks.Git.did(t)}]), true}
      end

    parts = %{
      "workbook.html" => html,
      "vfs.sqlite" => vfs_bytes
    }

    # Seal any gated entries: escrow a fresh content key per path, replace the part
    # with its sealed envelope, and collect key_refs for the manifest.
    {parts, key_refs} = seal_gated(parts, opts[:gated], id)

    manifest = %{
      "id" => id,
      "format" => "wbundle/1",
      "volumes" => if(opts[:include_private], do: Workbooks.VFS.volumes(), else: Workbooks.Private.public_volumes()),
      "signed" => signed,
      "private_included" => !!opts[:include_private],
      "created" => System.system_time(:second)
    }

    manifest = if map_size(key_refs) == 0, do: manifest, else: Map.put(manifest, "key_refs", key_refs)

    pack(Map.put(parts, "manifest.json", Jason.encode!(manifest)))
  end

  # Seal the gated paths via the runtime escrow keyfn, annotating each ref with the
  # AEAD algo (the manifest stays self-describing for any opener / the client).
  defp seal_gated(parts, gated, id) when is_list(gated) and gated != [] do
    keyfn = Workbooks.Bundle.Escrow.keyfn(to_string(id))
    {sealed, refs} = Workbooks.Bundle.Sealed.seal_entries(parts, gated, keyfn)
    refs = Map.new(refs, fn {path, ref} -> {path, Map.put(ref, "algo", "aes-256-gcm")} end)
    {sealed, refs}
  end

  defp seal_gated(parts, _none, _id), do: {parts, %{}}

  @doc "Restore a Bundle blob → {manifest, workbook_html, vfs_sqlite_bytes}."
  def restore(blob) when is_binary(blob) do
    parts = unpack(blob)
    {Jason.decode!(parts["manifest.json"]), parts["workbook.html"], parts["vfs.sqlite"]}
  end

  @doc """
  Open a shipped bundle's sealed entries, releasing keys through `provider`
  (`key_id -> {:ok, key} | {:error, reason}`). Public entries pass through; a
  denied release surfaces as `{:error, {path, reason}}` — the gate holds. Returns
  `{:ok, parts}` (all entries plaintext) or that error. With no `key_refs` in the
  manifest this is just `unpack/1`.
  """
  def open(blob, provider) when is_binary(blob) and is_function(provider, 1) do
    parts = unpack(blob)
    manifest = Jason.decode!(parts["manifest.json"])
    Workbooks.Bundle.Sealed.open_entries(parts, manifest["key_refs"] || %{}, provider)
  end

  @doc "Verify a shipped bundle's embedded provenance (signature + asset integrity)."
  def verify(blob) when is_binary(blob) do
    Workbooks.Manifest.verify(unpack(blob)["workbook.html"] || "")
  end
end
