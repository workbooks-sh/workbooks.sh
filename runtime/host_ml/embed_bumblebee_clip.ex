defmodule Workbooks.Embed.BumblebeeClip do
  @moduledoc """
  In-BEAM CLIP image+text embedder — Bumblebee + EXLA, served via `Nx.Serving`
  (one shared model, automatic request BATCHING, BEAM-supervised). This is the
  heavy embedder that runs INSIDE the BEAM and scales — the alternative to the
  Node sidecar. Image and text land in ONE space, so a text query retrieves
  images (cross-modal).

  Compiled ONLY when `WB_BUMBLEBEE=1` (this file lives in host_ml/, gated by
  elixirc_paths, and references Bumblebee directly). The registry reaches it via
  `Code.ensure_loaded?`, so the lean default build neither needs nor sees it.
  """
  @behaviour Workbooks.Embed
  @repo "openai/clip-vit-base-patch32"
  @pt {__MODULE__, :servings}

  @impl true
  def dim, do: 512

  @impl true
  def embed(inputs), do: embed(inputs, :text)

  def embed(inputs, :text) do
    run(servings().text, inputs)
  end

  def embed(inputs, :image) do
    run(servings().image, Enum.map(inputs, &load_image/1))
  end

  defp run(serving, batch) do
    {:ok, Enum.map(batch, fn x -> Nx.Serving.run(serving, x).embedding |> Nx.to_flat_list() end)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Load + serve the model once (persistent_term — shared across tenants).
  defp servings do
    case :persistent_term.get(@pt, nil) do
      nil ->
        # CLIP is two towers projecting into ONE joint space. The full model needs
        # BOTH inputs at once; for embeddings we load each tower separately with the
        # :for_embedding architecture (adds the projection head → joint 512-d space,
        # output key :embedding).
        {:ok, text_model} =
          Bumblebee.load_model({:hf, @repo}, module: Bumblebee.Text.ClipText, architecture: :for_embedding)

        {:ok, image_model} =
          Bumblebee.load_model({:hf, @repo}, module: Bumblebee.Vision.ClipVision, architecture: :for_embedding)

        {:ok, tok} = Bumblebee.load_tokenizer({:hf, @repo})
        {:ok, feat} = Bumblebee.load_featurizer({:hf, @repo})

        s = %{
          text: Bumblebee.Text.text_embedding(text_model, tok, output_attribute: :embedding, embedding_processor: :l2_norm, defn_options: [compiler: EXLA]),
          image: Bumblebee.Vision.image_embedding(image_model, feat, output_attribute: :embedding, embedding_processor: :l2_norm, defn_options: [compiler: EXLA])
        }

        :persistent_term.put(@pt, s)
        s

      s -> s
    end
  end

  # path | base64 → an Nx image tensor for the featurizer.
  defp load_image("data:" <> rest), do: rest |> String.replace(~r/^[^,]+,/, "") |> b64_image()
  defp load_image(<<>> <> path), do: (if File.exists?(path), do: StbImage.read_file!(path) |> StbImage.to_nx(), else: b64_image(path))

  defp b64_image(b64) do
    {:ok, img} = b64 |> Base.decode64!() |> StbImage.read_binary()
    StbImage.to_nx(img)
  end
end
