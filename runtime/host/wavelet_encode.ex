defmodule Workbooks.WaveletEncode do
  @moduledoc """
  IN-SANDBOX mp4 encode — closes the last wavelet bedrock gap. Runs the Forge
  `ffmpeg` lane's `wb_encode.wasm` (a minimal libav* PNG-sequence → mpeg4/mp4
  transcoder, NO native exec) under wasmtime via the generic CommandRegistry, so
  the wavelet render pipeline can mux frames → mp4 ENTIRELY in-guest instead of
  escaping to the host `Workbooks.FfmpegBroker` (native ffmpeg + libx264/GPL).

  Same intent shape as the broker (`frames_dir`, `out_path`, `fps`) but the encode
  happens in the wasm sandbox: no host ffmpeg, no native exec, no broker grant.

  Codec: H.264 via in-guest **libx264** (GPL, cross-compiled to wasm32-wasi) +
  `mp4` muxer + `png` decoder + native AAC audio — broadcast-quality (CRF 18,
  medium preset, High profile), matching the host broker's output WITHOUT native
  exec, so the broker is no longer needed for quality. A dependency-free `mpeg4`
  fallback remains via `vcodec: "mpeg4"` (or `WB_VCODEC=mpeg4`).

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
    # Always go through Compilers.build/1: it runs compilers/ffmpeg/build.sh (idempotent —
    # if wb_encode.wasm is already built it exits early WITHOUT recompiling), then content-
    # addresses + (re)registers the CURRENT on-disk wasm under CLI_BIN ("wb_encode"). This
    # picks up a rebuilt wasm (e.g. after a codec change) even when a stale registration for
    # the name persists from a prior boot — registry hot-swap replaces by content hash.
    case Workbooks.Compilers.build("ffmpeg") do
      {:ok, @command, _wasm} ->
        {:ok, @command}

      {:ok, other, _wasm} ->
        {:error, {:encode_lane_unexpected_name, other}}

      {:error, reason} ->
        {:error, {:encode_lane_build_failed, reason}}
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
    * `:vcodec` (`"h264"` | `"mpeg4"`, default `"h264"`) — video codec. `"h264"`
      uses the in-guest libx264 lane (broadcast quality); `"mpeg4"` uses the
      dependency-free built-in encoder. Both run fully in the wasm sandbox.
  """
  def encode(frames_dir, out_path, opts \\ [])
      when is_binary(frames_dir) and is_binary(out_path) and is_list(opts) do
    fps = Keyword.get(opts, :fps, 30)
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    audio = Keyword.get(opts, :audio)
    vcodec = Keyword.get(opts, :vcodec, "h264")

    frames_abs = Path.expand(frames_dir)
    out_abs = Path.expand(out_path)
    out_dir = Path.dirname(out_abs)
    out_base = Path.basename(out_abs)
    File.mkdir_p!(out_dir)

    with {:ok, audio_argv} <- stage_audio(audio, frames_abs),
         {:ok, _name} <- ensure_registered() do
      # driver argv positions: 4=audio (""=none), 5=vcodec. If a non-default vcodec is set
      # without audio, pad position 4 with "" so vcodec lands at position 5.
      tail =
        case {audio_argv, vcodec} do
          {a, "h264"} -> a
          {[], v} -> ["", v]
          {[a], v} -> [a, v]
        end

      argv =
        ["/in/#{@frame_pattern}", "/out/#{out_base}", Integer.to_string(fps)] ++ tail

      dirs = ["#{frames_abs}::/in", "#{out_dir}::/out"]
      # The encode is legitimately compute-heavy (H.264 of a multi-second clip burns far
      # more than any generic fuel default before finishing). Bound it by WALL-CLOCK
      # (`timeout_ms`) only — fuel: :unlimited drops the `-W fuel` cap so a real encode
      # isn't trapped mid-stream, while the wall-clock timeout still kills a runaway.
      ropts = [timeout_ms: timeout_ms, fuel: :unlimited]

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

  @doc """
  AUDIO-ONLY encode — no frames, no video. Decode an audio file (`mp3` / `aac` /
  `wav` / `m4a`) → resample → native AAC → ISO-BMFF `.m4a`, ENTIRELY in the wasm
  guest via the same `wb_encode.wasm` lane (the `audio` subcommand). Transcode or
  extract: an `.m4a`/`aac` input is re-encoded to a clean AAC track. NO host
  ffmpeg, NO native exec.

  The input is STAGED into a private scratch dir preopened at `/in` (wasi grants
  no host paths beyond explicit preopens); the output's parent is preopened at
  `/out`. Returns `{:ok, out_path}` | `{:error, reason}`.

  opts:
    * `:bitrate_kbps` (int, default 128) — target AAC bitrate.
    * `:timeout_ms` (int, default 600_000) — wall-clock cap on the wasm encode.
  """
  def encode_audio(in_path, out_path, opts \\ [])
      when is_binary(in_path) and is_binary(out_path) and is_list(opts) do
    bitrate = Keyword.get(opts, :bitrate_kbps, 128)
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)

    src = Path.expand(in_path)
    out_abs = Path.expand(out_path)
    out_dir = Path.dirname(out_abs)
    out_base = Path.basename(out_abs)

    cond do
      not File.regular?(src) ->
        {:error, {:audio_missing, in_path}}

      true ->
        File.mkdir_p!(out_dir)
        # Private scratch so the wasm sees ONLY the one staged input under /in.
        scratch = Path.join(System.tmp_dir!(), "wb_audio_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(scratch)
        ext = Path.extname(src)
        in_name = "in" <> if(ext == "", do: ".mp3", else: ext)
        staged = Path.join(scratch, in_name)

        try do
          with :ok <- cp(src, staged),
               {:ok, _name} <- ensure_registered() do
            argv = [
              "audio",
              "/in/#{in_name}",
              "/out/#{out_base}",
              Integer.to_string(bitrate)
            ]

            dirs = ["#{scratch}::/in", "#{out_dir}::/out"]
            ropts = [timeout_ms: timeout_ms, fuel: :unlimited]

            case Workbooks.CommandRegistry.run_status(@command, "", argv, dirs, ropts) do
              {:ok, _out, 0} ->
                if File.regular?(out_abs),
                  do: {:ok, out_abs},
                  else: {:error, :encode_produced_no_m4a}

              {:ok, out, status} ->
                {:error, {:encode_failed, status, String.slice(out, 0, 400)}}

              {:error, reason} ->
                {:error, {:encode_failed, reason}}
            end
          end
        after
          File.rm_rf(scratch)
        end
    end
  end

  defp cp(src, dest) do
    case File.cp(src, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:audio_stage_failed, reason}}
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
