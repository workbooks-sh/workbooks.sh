defmodule Workbooks.Embed.Model2Vec do
  @moduledoc """
  Static (Model2Vec / "potion") embeddings — PURE ELIXIR, no model runtime, no
  native NIF. A static embedding is just: tokenize → look up each token's vector
  in a precomputed matrix → mean-pool → normalize. No transformer forward pass, so
  the whole "model" is a vocab + a matrix (~8–30 MB), and inference is arithmetic.

  This is the smallest-to-ship, multi-tenant local embedder (one matrix resident,
  serves every tenant), satisfying "WASM or Elixir, no native NIF" via the Elixir
  path — nothing to compile, nothing to download at runtime but the matrix itself.
  Chosen over ORT-Web because it skips the runtime entirely (~3–5× smaller total).
  See docs/VECTOR-QUERY.org step 6.

  Loaded once into :persistent_term. `model` is %{vocab, unk, matrix, dim, normalize}.
  """

  @model_id "minishlab/potion-base-8M"
  @files ~w(config.json vocab.txt model.safetensors)
  @pt {__MODULE__, :model}

  @doc """
  The resident model — downloaded once to `<WB_DATA>/_models/<id>/` (cached on the
  storage volume across redeploys), loaded once into :persistent_term, then shared
  by every tenant. `WB_EMBED_MODEL` overrides the model id (any Model2Vec/potion).
  """
  def get do
    case :persistent_term.get(@pt, nil) do
      nil ->
        model = load(ensure_downloaded())
        :persistent_term.put(@pt, model)
        model

      model -> model
    end
  end

  defp ensure_downloaded do
    id = System.get_env("WB_EMBED_MODEL", @model_id)
    dir = Path.join([System.get_env("WB_DATA", "tmp/data"), "_models", Path.basename(id)])
    File.mkdir_p!(dir)

    Enum.each(@files, fn f ->
      path = Path.join(dir, f)
      unless File.exists?(path), do: fetch("https://huggingface.co/#{id}/resolve/main/#{f}", path)
    end)

    dir
  end

  defp fetch(url, path) do
    :inets.start()
    :ssl.start()
    req = {String.to_charlist(url), [{~c"user-agent", ~c"workbooks-runtime"}]}

    case :httpc.request(:get, req, [autoredirect: true, timeout: 180_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> File.write!(path, body)
      other -> raise "model download failed (#{url}): #{inspect(elem(other, 0))}"
    end
  end

  # ── load ──────────────────────────────────────────────────────────────────────
  @doc """
  Load a model from a dir holding `config.json`, `vocab.txt` (one token per line,
  line index = id), `model.safetensors` (a single F32 `embeddings` tensor). The
  matrix stays a BINARY (refc-shared, ~30 MB) with by-offset lookup — never a map
  of float-lists (which would balloon in the BEAM). Returns the model map.
  """
  def load(dir) do
    cfg = Path.join(dir, "config.json") |> File.read!() |> Jason.decode!()
    dim = cfg["hidden_dim"] || 256
    {vocab, unk} = load_vocab(Path.join(dir, "vocab.txt"))
    %{vocab: vocab, unk: unk, matrix: load_matrix(Path.join(dir, "model.safetensors")),
      dim: dim, normalize: cfg["normalize"] != false}
  end

  defp load_vocab(path) do
    vocab =
      File.read!(path)
      |> String.split("\n")
      |> Enum.with_index()
      |> Map.new(fn {tok, i} -> {tok, i} end)

    {vocab, Map.get(vocab, "[UNK]", 1)}
  end

  # safetensors: 8-byte LE header length, JSON header, then the tensor data. The
  # single `embeddings` tensor sits at data offset 0, so the data section IS the matrix.
  defp load_matrix(path) do
    <<hlen::little-unsigned-64, rest::binary>> = File.read!(path)
    <<_header::binary-size(hlen), data::binary>> = rest
    data
  end

  # ── inference ─────────────────────────────────────────────────────────────────
  @doc "Embed texts with a loaded model → [vector]."
  def embed(texts, model), do: Enum.map(texts, &embed_one(&1, model))

  defp embed_one(text, %{vocab: vocab, unk: unk, matrix: matrix, dim: dim} = model) do
    vecs =
      text
      |> tokenize(vocab, unk)
      |> Enum.map(&vec(matrix, &1, dim))

    pooled = mean_pool(vecs, dim)
    if Map.get(model, :normalize, true), do: l2(pooled), else: pooled
  end

  # Decode token `id`'s vector — a binary slice of `dim` little-endian f32 (the
  # real model) or a map entry (synthetic tests).
  defp vec(matrix, id, dim) when is_binary(matrix) do
    off = id * dim * 4
    if off >= 0 and off + dim * 4 <= byte_size(matrix),
      do: (for <<f::little-float-32 <- binary_part(matrix, off, dim * 4)>>, do: f),
      else: List.duplicate(0.0, dim)
  end

  defp vec(matrix, id, dim) when is_map(matrix), do: Map.get(matrix, id, List.duplicate(0.0, dim))

  # ── WordPiece tokenizer (pure Elixir — matches BERT-style models) ────────────
  defp tokenize(text, vocab, unk) do
    text
    |> String.downcase()
    |> pre_tokens()
    |> Enum.flat_map(&wordpiece(&1, vocab, unk))
  end

  # Split into word + punctuation tokens (BERT basic tokenizer, Unicode-aware).
  defp pre_tokens(text), do: Regex.scan(~r/\w+|[^\w\s]/u, text) |> Enum.map(&hd/1)

  defp wordpiece(word, vocab, unk), do: wp(String.graphemes(word), vocab, unk, true, [])

  defp wp([], _vocab, _unk, _first, acc), do: Enum.reverse(acc)

  defp wp(graphemes, vocab, unk, first, acc) do
    case longest_prefix(graphemes, vocab, first) do
      {id, rest} -> wp(rest, vocab, unk, false, [id | acc])
      # an unmatchable piece ⇒ this word is [UNK] (BERT WordPiece behavior); prior
      # words' tokens in `acc` are kept.
      :none -> Enum.reverse([unk | acc])
    end
  end

  defp longest_prefix(graphemes, vocab, first) do
    n = length(graphemes)

    Enum.find_value(n..1//-1, fn k ->
      {prefix, rest} = Enum.split(graphemes, k)
      tok = if(first, do: "", else: "##") <> Enum.join(prefix)
      case Map.get(vocab, tok), do: (nil -> nil; id -> {id, rest})
    end)
  end

  # ── vector math ───────────────────────────────────────────────────────────────
  defp mean_pool([], dim), do: List.duplicate(0.0, dim)

  defp mean_pool(vecs, _dim) do
    n = length(vecs)
    vecs |> Enum.zip_with(&Enum.sum/1) |> Enum.map(&(&1 / n))
  end

  defp l2(v) do
    norm = v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if norm == 0.0, do: v, else: Enum.map(v, &(&1 / norm))
  end
end
