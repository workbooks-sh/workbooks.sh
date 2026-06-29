defmodule Nexus.Embed.Model2Vec do
  @moduledoc """
  Static-embedding provider (Model2Vec / potion style) — the semantic upgrade at `Nexus.Embed`'s
  model-swap point, pure Elixir, **no NIF and no inference server**.

  Model2Vec distills a sentence-transformer into a token→vector table; embedding a text is then just
  *tokenize → look up → weighted mean-pool → L2-normalize*. That makes it MRL-friendly (a leading
  slice of the vector is itself a valid embedding) and cheap enough for hundreds of concurrent agents
  on a small box — exactly what the Skill-KB two-tier recall wants.

  ## Activating real semantics
  Drop a distilled table at the configured path (`deploy embed_model="…"`, or app env
  `:model2vec_path`) — an Erlang-term file `%{dim: d, vectors: %{token => [float]}, weights: %{token =>
  float} | nil}` (export once from any `minishlab/potion-*` model; the matrix + tokenizer vocab are the
  only facts needed). Until then this provider **falls back to `Nexus.Embed.Hashed`**, so swapping
  `deploy embed="model2vec"` never breaks ingest — quality simply tracks whether the table is present.

  OOV tokens back off to a deterministic hashed sub-vector in the same space, so out-of-vocabulary
  words still contribute signal rather than being dropped.
  """
  @behaviour Nexus.Embed

  @default_dim 256
  @pt_key {__MODULE__, :table}

  @impl true
  def dim, do: (table() && table().dim) || @default_dim

  @impl true
  def embed(texts), do: Enum.map(texts, &vec/1)

  @doc "Load (and cache) a token→vector table from `path`. Exposed so tests/tools can seed it."
  @spec load(String.t() | map) :: :ok
  def load(path) when is_binary(path) do
    table = path |> File.read!() |> :erlang.binary_to_term()
    put(normalize_table(table))
  end

  def load(%{dim: _} = table), do: put(normalize_table(table))

  @doc "Drop the cached table (tests)."
  def reset, do: :persistent_term.erase(@pt_key)

  # ── inference ──────────────────────────────────────────────────────────────

  defp vec(text) do
    case table() do
      nil ->
        # no artifact → honest fallback, never break the pipeline
        Nexus.Embed.Hashed.embed([text]) |> hd()

      %{dim: d, vectors: vectors, weights: weights} ->
        tokens = tokenize(text)

        {sum, wsum} =
          Enum.reduce(tokens, {zeros(d), 0.0}, fn tok, {acc, ws} ->
            w = (weights && Map.get(weights, tok, 1.0)) || 1.0
            v = Map.get(vectors, tok) || oov(tok, d)
            {add_scaled(acc, v, w), ws + w}
          end)

        sum |> scale(if(wsum == 0.0, do: 1.0, else: 1.0 / wsum)) |> l2()
    end
  end

  # Whitespace/punctuation word tokenizer, lowercased — matches the vocab convention of static models.
  defp tokenize(text) do
    text |> to_string() |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  # Deterministic unit sub-vector for an OOV token (signed hashing trick into d dims).
  defp oov(tok, d) do
    raw =
      for i <- 0..(d - 1) do
        h = :erlang.phash2({tok, i}, 1_000_003)
        if rem(h, 2) == 0, do: 1.0, else: -1.0
      end

    l2(raw)
  end

  # ── table cache ─────────────────────────────────────────────────────────────

  defp table do
    case :persistent_term.get(@pt_key, :unset) do
      :unset ->
        t = autoload()
        :persistent_term.put(@pt_key, t)
        t

      t ->
        t
    end
  end

  defp autoload do
    path =
      (Code.ensure_loaded?(Nexus.Config) and function_exported?(Nexus.Config, :get, 1) and Nexus.Config.get(:embed_model)) ||
        Application.get_env(:nexus, :model2vec_path)

    if is_binary(path) and File.exists?(path) do
      path |> File.read!() |> :erlang.binary_to_term() |> normalize_table()
    end
  rescue
    _ -> nil
  end

  defp put(table), do: :persistent_term.put(@pt_key, table)

  defp normalize_table(%{dim: d, vectors: v} = t), do: %{dim: d, vectors: v, weights: Map.get(t, :weights)}

  # ── vector math ─────────────────────────────────────────────────────────────

  defp zeros(d), do: List.duplicate(0.0, d)
  defp add_scaled(acc, v, w), do: Enum.zip_with(acc, v, fn a, x -> a + x * w end)
  defp scale(v, k), do: Enum.map(v, &(&1 * k))

  defp l2(v) do
    n = v |> Enum.reduce(0.0, fn x, a -> a + x * x end) |> :math.sqrt()
    if n == 0.0, do: v, else: Enum.map(v, &(&1 / n))
  end
end
