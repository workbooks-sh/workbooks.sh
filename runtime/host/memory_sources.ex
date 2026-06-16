defmodule Workbooks.MemorySources do
  @moduledoc """
  Workbook-as-memory loader (wb-kbq5.1): the desktop's memory panel loads a
  workbook file as a semantic-search source. Each load chunks the file, embeds
  the chunks (`Workbooks.Embed`), and upserts them into the vector store
  (`Workbooks.Vector`) tagged by the source path — so `work search` / retrieval
  surfaces them. A small JSON store tracks which paths are loaded (so GET can
  list them and DELETE can drop them).
  """
  alias Workbooks.{Embed, Vector}

  defp store_path, do: Path.join(System.get_env("WB_DATA") || System.tmp_dir!(), "wb-memory-sources.json")

  @doc "Loaded source paths for the tenant (the desktop's `loaded` list)."
  def list(_tenant \\ "dev"), do: read_store() |> Map.keys() |> Enum.sort()

  @doc """
  Load (index) a workbook file as a memory source. Re-indexable (forgets the
  path's prior vectors first). Returns {:ok, %{indexed_count, file_count}}.
  """
  def load(tenant, path) when is_binary(path) do
    abs = Path.expand(path)

    with true <- File.regular?(abs) or {:error, :enoent},
         {:ok, content} <- File.read(abs) do
      chunks = chunk(content)
      vectors = embed_chunks(chunks)

      Vector.forget(tenant, path)

      Enum.zip(chunks, vectors)
      |> Enum.with_index()
      |> Enum.each(fn {{chunk, vec}, i} ->
        Vector.upsert(tenant, "#{path}:#{i}", vec, %{
          workbook: path,
          path: path,
          headline: chunk.headline,
          text: chunk.text
        })
      end)

      n = length(vectors)
      put_store(path, n)
      {:ok, %{indexed_count: n, file_count: 1}}
    else
      {:error, _} = e -> e
      false -> {:error, :enoent}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Drop a loaded source. Returns {:ok, %{entry_count, file_count}}."
  def remove(tenant, path) when is_binary(path) do
    n = read_store() |> Map.get(path, 0)
    Vector.forget(tenant, path)
    drop_store(path)
    {:ok, %{entry_count: n, file_count: 1}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── chunking ─────────────────────────────────────────────────────────────--
  # Split on blank-line paragraph boundaries, carrying the most recent Org/MD
  # heading as the chunk's headline. Small + dependency-free; good enough for
  # retrieval over a single workbook.
  defp chunk(content) do
    content
    |> String.split("\n\n", trim: true)
    |> Enum.reduce({[], ""}, fn para, {acc, heading} ->
      heading = latest_heading(para) || heading
      text = String.trim(para)
      if text == "", do: {acc, heading}, else: {[%{headline: heading, text: text} | acc], heading}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp latest_heading(para) do
    para
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\*+\s+(.+)$|^#+\s+(.+)$/, String.trim(line)) do
        [_, h] -> h
        [_, _, h] -> h
        _ -> nil
      end
    end)
  end

  defp embed_chunks([]), do: []

  defp embed_chunks(chunks) do
    case Embed.embed(Enum.map(chunks, & &1.text)) do
      {:ok, vectors} -> vectors
      vectors when is_list(vectors) -> vectors
      _ -> Enum.map(chunks, fn _ -> [] end)
    end
  end

  # ── store (path → indexed_count) ───────────────────────────────────────────
  defp read_store do
    case File.read(store_path()) do
      {:ok, body} -> Jason.decode!(body)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp put_store(path, n), do: write_store(Map.put(read_store(), path, n))
  defp drop_store(path), do: write_store(Map.delete(read_store(), path))

  defp write_store(map) do
    File.write(store_path(), Jason.encode!(map))
  rescue
    _ -> :ok
  end
end
