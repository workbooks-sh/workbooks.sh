defmodule Workbooks.Embed.Capability do
  @moduledoc """
  Probe the machine and recommend an embedding tier — so the SAME runtime fits the
  system it's on: a CPU/cloud box stays on CLIP/Model2Vec; a local machine with a
  real accelerator (CUDA GPU, Apple-Silicon MPS) can default to a heavier
  multimodal model (VLM2Vec-class) served locally. Pure detection — no inference.

    :big_multimodal — accelerator + enough RAM (run a 7B VLM locally)
    :clip           — decent CPU/RAM (image+text in one space)
    :model2vec      — minimal (text only, always works)
  """

  @doc "Detected facts: %{os, cores, ram_gb, accelerator}."
  def probe do
    %{os: os(), cores: System.schedulers_online(), ram_gb: ram_gb(), accelerator: accelerator()}
  end

  @doc "The recommended tier for this machine."
  def recommend do
    p = probe()

    cond do
      p.accelerator != :none and p.ram_gb >= 16 -> :big_multimodal
      p.cores >= 4 and p.ram_gb >= 4 -> :clip
      true -> :model2vec
    end
  end

  defp os, do: elem(:os.type(), 1)

  defp ram_gb do
    bytes =
      case :os.type() do
        {:unix, :darwin} -> sh("sysctl -n hw.memsize") |> to_int()
        {:unix, _} -> (sh("awk '/MemTotal/{print $2*1024}' /proc/meminfo") |> to_int())
        _ -> 0
      end

    round(bytes / 1_073_741_824)
  end

  # A usable accelerator for local model inference, or :none.
  defp accelerator do
    cond do
      match?({_, 0}, System.cmd("sh", ["-c", "command -v nvidia-smi"], stderr_to_stdout: true)) -> :cuda
      :os.type() == {:unix, :darwin} and String.trim(sh("uname -m")) == "arm64" -> :mps
      true -> :none
    end
  rescue
    _ -> :none
  end

  defp sh(cmd) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true), do: ({out, 0} -> out; _ -> "")
  rescue
    _ -> ""
  end

  defp to_int(s), do: (case Integer.parse(String.trim(s)), do: ({n, _} -> n; _ -> 0))
end
