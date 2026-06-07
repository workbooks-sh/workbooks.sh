defmodule Workbooks.Embed.OrtexClip do
  @moduledoc """
  In-BEAM CLIP image+text embedder — ONNX via Ortex (onnxruntime), LIGHT. Two q8
  CLIP towers (~147 MB) project into ONE 512-d joint space, so a text query
  retrieves images (cross-modal). No XLA, no JIT — the small in-process path that
  replaced the EXLA/Bumblebee build and the Node sidecar.

  Compiled ONLY when `WB_CLIP=1` (this file lives in host_ml/, gated by
  elixirc_paths, and references Ortex/Tokenizers directly). The registry reaches it
  via `Code.ensure_loaded?`, so the lean default build neither needs nor sees it.

  Assets (q8 ONNX + tokenizer) cache under `WB_CLIP_DIR` (default
  `$WB_MODELS_DIR/clip`, else `~/.cache/workbooks/clip`); missing files download
  from `Xenova/clip-vit-base-patch32` on first use.
  """
  @behaviour Workbooks.Embed
  @pt {__MODULE__, :state}
  @repo "https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main"
  @files %{
    "text_model_quantized.onnx" => "/onnx/text_model_quantized.onnx",
    "vision_model_quantized.onnx" => "/onnx/vision_model_quantized.onnx",
    "tokenizer.json" => "/tokenizer.json"
  }
  @ctx 77
  @mean Nx.tensor([0.48145466, 0.4578275, 0.40821073]) |> Nx.reshape({3, 1, 1})
  @std Nx.tensor([0.26862954, 0.26130258, 0.27577711]) |> Nx.reshape({3, 1, 1})

  @impl true
  def dim, do: 512

  @impl true
  def embed(inputs), do: embed(inputs, :text)

  def embed(inputs, :text), do: run(:text, Enum.map(inputs, &text_inputs/1))
  def embed(inputs, :image), do: run(:image, Enum.map(inputs, &image_input/1))

  defp run(tower, tensors) do
    s = state()
    model = Map.fetch!(s, tower)
    {:ok, Enum.map(tensors, fn t -> l2(infer(model, tower, t)) |> Nx.to_flat_list() end)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # text: {input_ids, attention_mask}; image: {pixel_values}. The first output is
  # the projected embedding (text_embeds / image_embeds), already in joint space.
  defp infer(model, :text, {ids, mask}), do: Ortex.run(model, {ids, mask}) |> elem(0)
  defp infer(model, :image, pixels), do: Ortex.run(model, {pixels}) |> elem(0)

  defp l2(t) do
    # Ortex outputs live on Ortex.Backend (limited ops) — pull to the default
    # backend before normalizing.
    t = Nx.backend_transfer(t) |> Nx.reshape({:auto}) |> Nx.as_type(:f32)
    n = Nx.sqrt(Nx.sum(Nx.pow(t, 2)))
    Nx.divide(t, Nx.add(n, 1.0e-12))
  end

  # ---- text ----------------------------------------------------------------
  defp text_inputs(text) do
    {:ok, enc} = Tokenizers.Tokenizer.encode(tokenizer(), text, add_special_tokens: true)
    ids = Tokenizers.Encoding.get_ids(enc)
    mask = Tokenizers.Encoding.get_attention_mask(enc)
    {pad_row(ids), pad_row(mask)}
  end

  defp pad_row(list) do
    list = Enum.take(list, @ctx)
    list = list ++ List.duplicate(0, @ctx - length(list))
    Nx.tensor([list], type: :s64)
  end

  # ---- image ---------------------------------------------------------------
  # path | data-uri | base64 → CLIP pixel_values [1,3,224,224] f32 (resize shortest
  # edge 224, center-crop 224, /255, normalize by CLIP mean/std, HWC→CHW).
  defp image_input(spec) do
    img = load_image(spec)
    {h, w, _} = img.shape
    scale = 224 / min(h, w)
    rh = round(h * scale)
    rw = round(w * scale)

    img
    |> StbImage.from_nx()
    |> StbImage.resize(rh, rw)
    |> StbImage.to_nx()
    |> Nx.as_type(:f32)
    |> Nx.divide(255.0)
    |> Nx.transpose(axes: [2, 0, 1])
    |> center_crop(rh, rw)
    |> Nx.subtract(@mean)
    |> Nx.divide(@std)
    |> Nx.new_axis(0)
  end

  defp center_crop(chw, h, w) do
    top = div(h - 224, 2)
    left = div(w - 224, 2)
    Nx.slice(chw, [0, top, left], [3, 224, 224])
  end

  defp load_image("data:" <> rest), do: rest |> String.replace(~r/^[^,]+,/, "") |> b64_image()
  defp load_image(<<>> <> path) do
    if File.exists?(path), do: StbImage.read_file!(path) |> StbImage.to_nx(), else: b64_image(path)
  end

  defp b64_image(b64) do
    {:ok, img} = b64 |> Base.decode64!() |> StbImage.read_binary()
    StbImage.to_nx(img)
  end

  # ---- load once (persistent_term, shared across tenants) -------------------
  defp tokenizer, do: state().tokenizer

  defp state do
    case :persistent_term.get(@pt, nil) do
      nil ->
        dir = ensure_assets()
        {:ok, tok} = Tokenizers.Tokenizer.from_file(Path.join(dir, "tokenizer.json"))
        s = %{
          text: Ortex.load(Path.join(dir, "text_model_quantized.onnx")),
          image: Ortex.load(Path.join(dir, "vision_model_quantized.onnx")),
          tokenizer: tok
        }
        :persistent_term.put(@pt, s)
        s

      s -> s
    end
  end

  defp ensure_assets do
    dir = cache_dir()
    File.mkdir_p!(dir)

    for {name, path} <- @files do
      file = Path.join(dir, name)
      unless File.exists?(file), do: download(@repo <> path, file)
    end

    dir
  end

  defp cache_dir do
    System.get_env("WB_CLIP_DIR") ||
      case System.get_env("WB_MODELS_DIR") do
        nil -> Path.join([System.user_home!(), ".cache", "workbooks", "clip"])
        m -> Path.join(m, "clip")
      end
  end

  defp download(url, dest) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [autoredirect: true], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> File.write!(dest, body)
      other -> raise "CLIP asset download failed (#{url}): #{inspect(other)}"
    end
  end
end
