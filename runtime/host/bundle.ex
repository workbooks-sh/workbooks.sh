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
  """
  def ship(id, html, vfs_bytes) when is_binary(vfs_bytes) do
    manifest = %{
      "id" => id,
      "format" => "wbundle/1",
      "volumes" => Workbooks.VFS.volumes(),
      "created" => System.system_time(:second)
    }

    pack(%{
      "manifest.json" => Jason.encode!(manifest),
      "workbook.html" => html,
      "vfs.sqlite" => vfs_bytes
    })
  end

  @doc "Restore a Bundle blob → {manifest, workbook_html, vfs_sqlite_bytes}."
  def restore(blob) when is_binary(blob) do
    parts = unpack(blob)
    {Jason.decode!(parts["manifest.json"]), parts["workbook.html"], parts["vfs.sqlite"]}
  end
end
