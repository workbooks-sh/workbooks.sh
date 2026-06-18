defmodule Nexus.Ether.Tier do
  @moduledoc """
  Pick the local model + quant + GPU-offload per lane from the machine's actual specs.

  A user's box decides what the two brains can be: a 16GB Mac can pair a small AR model with a
  mid omni model, but not the 26B diffusion brain; a 64GB box runs the full pair. `detect/0` probes
  cores / memory / GPU; `recommend/1` turns that into a lane config:

    * **CPU lane** — autoregressive, `ngl: 0` (pure CPU), `threads` = perf-ish cores.
    * **GPU lane** — the largest model that still leaves headroom beside the CPU model, `ngl: 99`
      (all layers on Metal/GPU). `nil` when there's no GPU or no room → CPU-only, single brain.

  Quant is Q4 by default (the on-device sweet spot); bumps to Q5 only when memory is plentiful.
  Detection is best-effort and read-only (sysctl on macOS, /proc + nvidia-smi on Linux); unknowns
  fall back to the safe small tier rather than raising.
  """

  # name => approx resident GB at Q4_K_M
  @sizes %{
    "granite-4.1-3b" => 2,
    "granite-4.1-8b" => 5,
    "gemma-4-e4b" => 5,
    "gemma-4-12b" => 7,
    "diffusion-gemma" => 14
  }

  @doc "Machine specs: %{os, cores, mem_gb, gpu: :metal | :cuda | :none}."
  def detect do
    %{os: os(), cores: System.schedulers_online(), mem_gb: mem_gb(), gpu: gpu()}
  end

  @doc """
  Lane recommendation from specs (defaults to `detect/0`):
  `%{cpu: %{model, quant, ngl, threads}, gpu: %{model, quant, ngl} | nil, two_brain?, notes}`.
  """
  def recommend(specs \\ detect()) do
    quant = if specs.mem_gb >= 32, do: "Q5_K_M", else: "Q4_K_M"
    cpu_model = if specs.mem_gb >= 24, do: "granite-4.1-8b", else: "granite-4.1-3b"
    threads = max(1, specs.cores - 2)
    cpu = %{model: cpu_model, quant: quant, ngl: 0, threads: threads}

    gpu =
      if specs.gpu == :none do
        nil
      else
        headroom = 3
        budget = specs.mem_gb - @sizes[cpu_model] - headroom

        case fits(budget) do
          nil -> nil
          model -> %{model: model, quant: quant, ngl: 99}
        end
      end

    %{cpu: cpu, gpu: gpu, two_brain?: gpu != nil, notes: notes(specs, gpu)}
  end

  # Largest GPU-lane model whose Q4 footprint fits the remaining budget (GB).
  defp fits(budget) do
    ["diffusion-gemma", "gemma-4-12b", "gemma-4-e4b"]
    |> Enum.find(fn m -> @sizes[m] <= budget end)
  end

  defp notes(specs, nil),
    do: "CPU-only (#{specs.mem_gb}GB, gpu=#{specs.gpu}): single brain, no concurrent GPU lane."

  defp notes(specs, %{model: "diffusion-gemma"}),
    do: "Full two-brain: AR on CPU + DiffusionGemma on GPU (#{specs.mem_gb}GB)."

  defp notes(specs, gpu),
    do: "Two-brain: AR on CPU + #{gpu.model} on GPU (#{specs.mem_gb}GB; DiffusionGemma needs ~32GB+)."

  # --- probes (best-effort, read-only) ---

  defp os, do: :os.type() |> elem(1)

  defp mem_gb do
    case :os.type() do
      {:unix, :darwin} -> sysctl_int("hw.memsize") |> bytes_to_gb()
      {:unix, _} -> meminfo_kb() |> kb_to_gb()
      _ -> 8
    end
  end

  defp gpu do
    case :os.type() do
      {:unix, :darwin} -> :metal
      {:unix, _} -> if cmd_ok?("nvidia-smi", ["-L"]), do: :cuda, else: :none
      _ -> :none
    end
  end

  defp sysctl_int(key) do
    case cmd("sysctl", ["-n", key]) do
      {out, 0} -> out |> String.trim() |> Integer.parse() |> then(fn {n, _} -> n; :error -> 0 end)
      _ -> 0
    end
  end

  defp meminfo_kb do
    case File.read("/proc/meminfo") do
      {:ok, c} ->
        case Regex.run(~r/MemTotal:\s+(\d+) kB/, c) do
          [_, kb] -> String.to_integer(kb)
          _ -> 8 * 1024 * 1024
        end

      _ -> 8 * 1024 * 1024
    end
  end

  defp bytes_to_gb(0), do: 8
  defp bytes_to_gb(b), do: round(b / 1_073_741_824)
  defp kb_to_gb(kb), do: max(1, round(kb / 1_048_576))

  defp cmd(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  defp cmd_ok?(bin, args), do: match?({_, 0}, cmd(bin, args))
end
