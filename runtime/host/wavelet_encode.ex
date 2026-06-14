defmodule Workbooks.WaveletEncode do
  @moduledoc """
  IN-SANDBOX mp4 encode — closes the last wavelet bedrock gap. Runs the Forge
  `ffmpeg` lane's `wb_encode.wasm` (a minimal libav* PNG-sequence → mpeg4/mp4
  transcoder, NO native exec) under wasmtime via the generic CommandRegistry, so
  the wavelet render pipeline can mux frames → mp4 ENTIRELY in-guest instead of
  escaping to the host `Workbooks.FfmpegBroker` (native ffmpeg + libx264/GPL).

  Same intent shape as the broker (`frames_dir`, `out_path`, `fps`) but the encode
  happens in the wasm sandbox: no host ffmpeg, no native exec, no broker grant.

  Codec: built-in `mpeg4` video + `mp4` muxer + `png` decoder (dependency-free,
  universally playable). H.264 quality is the libx264 follow-on — for now the host
  broker remains the H.264 path; this is the zero-trust, no-native-exec default.

  Provisioning mirrors the other compiler lanes: `Workbooks.Compilers.build/1` runs
  `runtime/compilers/ffmpeg/build.sh` (cross-compiles wb_encode.wasm with wasi-sdk),
  and registers it under the `#{inspect("wb-encode")}` command. Idempotent + content-
  addressed, so a re-build/re-register is a no-op.
  """

  # The Forge ffmpeg lane (compilers/ffmpeg/manifest.org) registers its artifact under
  # CLI_BIN = "wb_encode" via Compilers.build/1. We run that command directly.
  @command "wb_encode"
  @frame_pattern "frame_%05d.png"

  @doc "The CommandRegistry name the in-guest encoder wasm is registered under."
  def encode_command, do: @command

  @doc """
  Ensure `wb_encode.wasm` is built (Forge ffmpeg lane) and registered as a command.
  Returns `{:ok, name}` | `{:error, reason}`. Idempotent.
  """
  def ensure_registered do
    if @command in Workbooks.CommandRegistry.list() do
      {:ok, @command}
    else
      # Compilers.build/1 runs compilers/ffmpeg/build.sh (cross-compiles wb_encode.wasm
      # with wasi-sdk), content-addresses it, and registers it under CLI_BIN ("wb_encode").
      case Workbooks.Compilers.build("ffmpeg") do
        {:ok, @command, _wasm} ->
          {:ok, @command}

        {:ok, other, _wasm} ->
          {:error, {:encode_lane_unexpected_name, other}}

        {:error, reason} ->
          {:error, {:encode_lane_build_failed, reason}}
      end
    end
  end

  @doc """
  Encode a `frame_%05d.png` sequence in `frames_dir` into an mp4 at `out_path`,
  IN-SANDBOX. The frames dir is preopened at `/in`, the output's parent at `/out`.
  Returns `{:ok, out_path}` | `{:error, reason}`.

  opts:
    * `:fps` (int, default 30)
    * `:timeout_ms` (int, default 600_000) — wall-clock cap on the wasm encode.
    * `:audio` (path | nil) — optional audio file (mp3/aac/wav). When set, the
      file is STAGED INTO `frames_dir` (so it's reachable under the single `/in`
      preopen — wasi grants no host paths beyond the explicit preopens) and the
      driver decodes → resamples → encodes a native AAC track muxed alongside the
      video. NO host ffmpeg, NO native exec — the audio mux is fully in-guest.
  """
  def encode(frames_dir, out_path, opts \\ [])
      when is_binary(frames_dir) and is_binary(out_path) and is_list(opts) do
    fps = Keyword.get(opts, :fps, 30)
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    audio = Keyword.get(opts, :audio)

    frames_abs = Path.expand(frames_dir)
    out_abs = Path.expand(out_path)
    out_dir = Path.dirname(out_abs)
    out_base = Path.basename(out_abs)
    File.mkdir_p!(out_dir)

    with {:ok, audio_argv} <- stage_audio(audio, frames_abs),
         {:ok, _name} <- ensure_registered() do
      argv =
        ["/in/#{@frame_pattern}", "/out/#{out_base}", Integer.to_string(fps)] ++ audio_argv

      dirs = ["#{frames_abs}::/in", "#{out_dir}::/out"]
      ropts = [timeout_ms: timeout_ms, fuel: 500_000_000_000]

      case Workbooks.CommandRegistry.run_status(@command, "", argv, dirs, ropts) do
        {:ok, _out, 0} ->
          if File.regular?(out_abs),
            do: {:ok, out_abs},
            else: {:error, :encode_produced_no_mp4}

        {:ok, out, status} ->
          {:error, {:encode_failed, status, String.slice(out, 0, 400)}}

        {:error, reason} ->
          {:error, {:encode_failed, reason}}
      end
    end
  end

  @doc "The frame-filename pattern the in-guest encoder expects (wavelet render_seq layout)."
  def frame_pattern, do: @frame_pattern

  # Stage the optional audio source INTO the frames dir so it's reachable under the
  # single `/in` wasi preopen, then return the driver's 4th argv (the in-guest path).
  # `nil` → no audio argv. The source may live anywhere on the host; we copy a single
  # known-named file (`audio<ext>`) next to the frames so the sandbox sees only it.
  defp stage_audio(nil, _frames_abs), do: {:ok, []}

  defp stage_audio(audio, frames_abs) when is_binary(audio) do
    src = Path.expand(audio)

    cond do
      not File.regular?(src) ->
        {:error, {:audio_missing, audio}}

      true ->
        ext = Path.extname(src)
        name = "audio" <> if(ext == "", do: ".mp3", else: ext)
        dest = Path.join(frames_abs, name)

        case File.cp(src, dest) do
          :ok -> {:ok, ["/in/#{name}"]}
          {:error, reason} -> {:error, {:audio_stage_failed, reason}}
        end
    end
  end
end
