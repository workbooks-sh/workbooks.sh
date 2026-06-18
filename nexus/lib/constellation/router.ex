defmodule Nexus.Ether.Router do
  @moduledoc """
  Ether routing — PICK ONE lane for a turn (vs Ether fusion, which joins both). Every decision is
  transparent: `decide/2` returns `{lane, reason}` so you can see *why* a turn went where.

  ## Task taxonomy (which brain, and why)

  Grounded in what each brain is good at:

    * **GPU lane (diffusion)** — parallel-block generation: fast, bidirectional, strong at
      fill-in-the-middle. Route here: `:infill`, `:edit`, `:draft`, `:classify`, `:route`.
    * **CPU lane (autoregressive)** — sequential, deliberate, strong tool-calling/reasoning.
      Route here (the default): `:chat`, `:orchestrate`, `:tools`, `:reason`, and anything unknown.

  ## Three tiers, cheapest first (no transformer, no heavy deps)

    1. **explicit tag** — caller passes a `task_type`; mapped by the taxonomy above. <1ms.
    2. **content heuristic** — untagged text is keyword-bucketed by `classify/1`. Swap in a smarter
       classifier with `config :nexus, Nexus.Ether, classifier: MyMod` (static-embedding or
       Bumblebee/ONNX) — no caller change.
    3. **load-aware spill** — a *spillable* GPU task moves to an idle CPU lane when the serial GPU
       queue is backed up. GPU-*required* work (true diffusion infill/edit) always waits for the GPU.
  """
  alias Nexus.Ether.Lane

  @doc "Classify a free-text prompt to a lane. Override the default heuristic with a `:classifier`."
  @callback classify(String.t()) :: :cpu | :gpu

  @gpu_types [:infill, :edit, :draft, :classify, :route]
  # GPU work that may fall back to CPU under GPU pressure (vs :infill/:edit, which truly need diffusion).
  @spillable [:draft, :classify, :route]

  @doc """
  Decide the lane for `type`, returning `{lane, reason}`. `type` may be a task atom or a free-text
  prompt (string, classified by content). Applies load-aware spill last.
  """
  def decide(type, opts \\ [])

  # Untagged text: classify to a lane (content guesses are soft → spillable).
  def decide(text, _opts) when is_binary(text),
    do: apply_spill(classify(text), true, :content)

  # Explicit task type: map via taxonomy; spillable only for the soft GPU types.
  def decide(type, _opts) when is_atom(type),
    do: apply_spill(base_lane(type), type in @spillable, :explicit)

  # A GPU pick spills to CPU only if it's spillable AND the GPU is backed up while CPU is free.
  defp apply_spill(:gpu, spillable?, via) do
    if spillable? and gpu_pressed?() and cpu_free?(),
      do: {:cpu, {:spill, via}},
      else: {:gpu, via}
  end

  defp apply_spill(:cpu, _spillable?, via), do: {:cpu, via}

  # Load checks are fail-safe: if a lane isn't running, treat it as "no spill" rather than crash.
  defp stat(lane) do
    if GenServer.whereis(lane), do: Lane.stat(lane), else: nil
  end

  @doc "Just the lane (drops the reason). Used by `Nexus.Ether.run/3`."
  def dispatch(type, _base_lane), do: decide(type) |> elem(0)

  @doc "Base lane from the task taxonomy, before any spill."
  def base_lane(type) when type in @gpu_types, do: :gpu
  def base_lane(_), do: :cpu

  @doc "Lane for an untagged prompt: configured `:classifier` module, else the keyword heuristic."
  def classify(text) when is_binary(text) do
    case Application.get_env(:nexus, Nexus.Ether, [])[:classifier] do
      nil -> keyword(text)
      mod -> mod.classify(text)
    end
  end

  # Coarse keyword bucket — diffusion-favorable edits/infill → GPU, everything else → CPU.
  defp keyword(text) do
    t = String.downcase(text)

    gpu_cues = [
      "fix the", "edit ", "rewrite", "fill in", "complete the", "infill",
      "insert ", "refactor", "classify", "which one", "translate"
    ]

    if Enum.any?(gpu_cues, &String.contains?(t, &1)), do: :gpu, else: :cpu
  end

  defp gpu_pressed? do
    s = stat(Nexus.Ether.GPU)
    s != nil and s.queued > 0
  end

  defp cpu_free? do
    s = stat(Nexus.Ether.CPU)
    s != nil and s.running < s.slots
  end
end
