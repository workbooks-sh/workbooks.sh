defmodule Workbooks.FfmpegBroker do
  @moduledoc """
  wb-broker ENCODE (the one bedrock escape) — a host-side TRUSTED service that owns `ffmpeg` and turns a
  tenant's rendered FRAME SEQUENCE into an mp4. ffmpeg is a native binary that cannot run inside the wasm
  sandbox (no native exec in the guest = BEDROCK); the canonical escape is a trusted host-service broker.
  The tenant only hands over FRAMES + INTENT (fps, optional audio); the host performs the privileged native
  encode. Mirrors the brokered-tools / curl-class `http` shape: a named capability the guest calls, with the
  host owning the privileged thing (there: the socket; here: ffmpeg + the filesystem).

  Pipeline (deterministic, no shell — every arg is a STRUCTURAL token handed straight to ffmpeg):

      frame_%05d.png (in a tenant dir) + fps  ->  H.264 (libx264, yuv420p, +faststart) mp4
      + optional audio.mp3                     ->  AAC audio track, shortest-stream muxed

  Security cadence (mirrors the net/exec/build brokers):
    * DEFAULT-DENY — encode only runs when the caller's profile GRANTS it (`:allow`, derived from the
      `encode` cap). No grant -> `{:error, :denied}`, nothing executes.
    * PATH-GATING — the frames dir, the audio file, and the output path must ALL canonicalize to strictly
      inside the broker's roots (one of the configured `:roots`, default `WB_ENCODE_ROOT` / a per-run sandbox
      base). No arbitrary fs: a `../` traversal or an absolute `/etc/...` is refused PRE-EXEC. The guest never
      names a host-absolute path the host doesn't own.
    * NO INJECTION / NO ARG-SMUGGLING — argv is a structural list to `System.cmd` (never a shell string), and
      every NUMERIC intent (fps, w, h, crf) is validated to a bounded integer before it can reach ffmpeg, so
      a hostile "fps" can't smuggle an ffmpeg flag.
    * BOUNDED INPUT — frame-count cap + per-frame extension allow-list (png only) + output-size readback cap;
      a wall-clock timeout on the ffmpeg process (DoS / runaway-encode defense).
    * REVOCATION + RATE — a revoked principal is refused; an optional per-principal rate quota applies.
    * AUDIT — every allow/deny is recorded (`Workbooks.BrokerAudit`, broker `:encode`).
  """
  require Logger

  # frame filename pattern the renderer (wavelet-render-core render_seq) emits: frame_00000.png …
  @frame_glob_re ~r/^frame_(\d{5})\.png$/
  @frame_pattern "frame_%05d.png"

  # Bounds (DoS backstops). 36000 frames = 20 min @ 30fps — generous for a clip, tight enough to bound work.
  @max_frames 36_000
  @min_fps 1
  @max_fps 240
  @default_crf 18
  @min_crf 0
  @max_crf 51
  @default_timeout_ms 600_000
  # readback cap on the produced mp4 when the caller asks for the BYTES (path mode is unbounded on disk).
  @max_output_bytes 512 * 1024 * 1024

  @doc """
  Encode a frame sequence into an mp4. Returns `{:ok, out_path}` | `{:error, reason}`.

  Required:
    * `frames_dir` — a directory of `frame_%05d.png` (the wavelet render_seq layout).
    * `out_path`   — where to write the mp4.

  opts:
    * `:allow` (bool, DEFAULT false) — the caller's profile grants encode (the `encode` cap). Default-deny.
    * `:fps` (int, default 30) — playback frame rate. Bounded [#{@min_fps}, #{@max_fps}].
    * `:audio` (path | nil) — an mp3 to mux as an AAC track (shortest stream wins).
    * `:crf` (int, default #{@default_crf}) — libx264 quality. Bounded [#{@min_crf}, #{@max_crf}].
    * `:roots` ([dir]) — the path-gating allow-list; every input/output must live inside one. Defaults to
      `default_roots/0` (`WB_ENCODE_ROOT`, else the system tmp dir).
    * `:timeout_ms` (int) — wall-clock cap on the ffmpeg process.
    * `:principal` — for revocation + rate checks + audit.
    * `:rate` ({max, window_ms}) — per-principal rate quota.
  """
  def encode(frames_dir, out_path, opts \\ [])
      when is_binary(frames_dir) and is_binary(out_path) and is_list(opts) do
    allow = Keyword.get(opts, :allow, false)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate)
    roots = Keyword.get(opts, :roots, default_roots())
    audio = Keyword.get(opts, :audio)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with :ok <- check_grant(allow),
         :ok <- check_principal(principal, rate),
         {:ok, fps} <- bounded_int(Keyword.get(opts, :fps, 30), @min_fps, @max_fps, :fps),
         {:ok, crf} <- bounded_int(Keyword.get(opts, :crf, @default_crf), @min_crf, @max_crf, :crf),
         {:ok, gated_frames} <- gate_existing_dir(frames_dir, roots),
         {:ok, gated_out} <- gate_output(out_path, roots),
         {:ok, gated_audio} <- gate_audio(audio, roots),
         {:ok, frame_count} <- count_frames(gated_frames),
         :ok <- ensure_ffmpeg() do
      run_ffmpeg(gated_frames, gated_out, gated_audio, fps, crf, frame_count, timeout_ms, principal)
    else
      {:error, reason} ->
        deny(reason, target_of(frames_dir, out_path))
        {:error, reason}
    end
  end

  @doc """
  Same as `encode/3` but returns the produced mp4 BYTES (`{:ok, binary}`) — for a tenant that wants the
  artifact in-hand rather than a host path. The mp4 is written to a gated temp output then read back (capped
  at #{div(@max_output_bytes, 1024 * 1024)} MB). The temp file is removed after readback.
  """
  def encode_to_bytes(frames_dir, opts \\ []) when is_binary(frames_dir) and is_list(opts) do
    roots = Keyword.get(opts, :roots, default_roots())
    root = List.first(roots) || System.tmp_dir!()
    out = Path.join(root, "wb_encode_#{System.unique_integer([:positive])}.mp4")

    try do
      case encode(frames_dir, out, Keyword.put(opts, :roots, roots)) do
        {:ok, path} ->
          case File.read(path) do
            {:ok, bin} when byte_size(bin) <= @max_output_bytes -> {:ok, bin}
            {:ok, _big} -> {:error, :output_too_large}
            {:error, e} -> {:error, {:read_failed, e}}
          end

        {:error, _} = err ->
          err
      end
    after
      File.rm(out)
    end
  end

  @doc "The frame-filename pattern the broker expects (the wavelet render_seq layout)."
  def frame_pattern, do: @frame_pattern

  @doc """
  Default path-gating roots: `WB_ENCODE_ROOT` if set, else the system tmp dir. A deployment confines the
  broker to a single sandbox-shared scratch area by setting `WB_ENCODE_ROOT`.
  """
  def default_roots do
    case System.get_env("WB_ENCODE_ROOT") do
      nil -> [System.tmp_dir!()]
      "" -> [System.tmp_dir!()]
      dir -> [dir]
    end
  end

  # ── checks ──────────────────────────────────────────────────────────────────

  defp check_grant(true), do: :ok
  defp check_grant(_), do: {:error, :denied}

  defp check_principal(nil, _rate), do: :ok

  defp check_principal(principal, rate) do
    cond do
      Workbooks.Revocation.revoked?(principal) -> {:error, :revoked}
      rate && rate_denied?(principal, rate) -> {:error, :rate_limited}
      true -> :ok
    end
  end

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  # bounded integer: accepts an int or an int-string; rejects anything outside [lo, hi]. This is the
  # arg-smuggling defense for every numeric intent — a non-integer fps can NEVER become an ffmpeg token.
  defp bounded_int(v, lo, hi, _name) when is_integer(v) and v >= lo and v <= hi, do: {:ok, v}

  defp bounded_int(v, lo, hi, name) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> bounded_int(n, lo, hi, name)
      _ -> {:error, {:invalid, name}}
    end
  end

  defp bounded_int(_v, _lo, _hi, name), do: {:error, {:invalid, name}}

  # ── path gating ─────────────────────────────────────────────────────────────

  # A path is gated iff its expansion (resolving `..`) lives strictly inside one of the roots. This is the
  # "no arbitrary fs" property: traversal and absolute escapes are refused before any fs touch.
  defp under_root?(abs, roots) do
    Enum.any?(roots, fn root ->
      r = Path.expand(root)
      abs == r or String.starts_with?(abs, r <> "/")
    end)
  end

  defp gate_existing_dir(path, roots) do
    abs = Path.expand(path)

    cond do
      not under_root?(abs, roots) -> {:error, :path_not_gated}
      not File.dir?(abs) -> {:error, :frames_dir_missing}
      true -> {:ok, abs}
    end
  end

  defp gate_output(path, roots) do
    abs = Path.expand(path)
    parent = Path.dirname(abs)

    cond do
      not under_root?(abs, roots) -> {:error, :path_not_gated}
      not File.dir?(parent) -> {:error, :output_dir_missing}
      true -> {:ok, abs}
    end
  end

  defp gate_audio(nil, _roots), do: {:ok, nil}

  defp gate_audio(path, roots) when is_binary(path) do
    abs = Path.expand(path)

    cond do
      not under_root?(abs, roots) -> {:error, :audio_not_gated}
      not File.regular?(abs) -> {:error, :audio_missing}
      true -> {:ok, abs}
    end
  end

  # Count the frame_%05d.png files and assert they form a contiguous 0..N-1 run (ffmpeg's image2 demuxer
  # needs a gapless sequence). Also enforces the per-encode frame cap.
  defp count_frames(dir) do
    nums =
      dir
      |> File.ls!()
      |> Enum.flat_map(fn name ->
        case Regex.run(@frame_glob_re, name) do
          [_, d] -> [String.to_integer(d)]
          _ -> []
        end
      end)
      |> Enum.sort()

    cond do
      nums == [] -> {:error, :no_frames}
      length(nums) > @max_frames -> {:error, :too_many_frames}
      nums != Enum.to_list(0..(length(nums) - 1)) -> {:error, :non_contiguous_frames}
      true -> {:ok, length(nums)}
    end
  end

  defp ensure_ffmpeg do
    if System.find_executable("ffmpeg"), do: :ok, else: {:error, :ffmpeg_missing}
  end

  # ── the privileged native encode ────────────────────────────────────────────

  defp run_ffmpeg(frames_dir, out, audio, fps, crf, frame_count, timeout_ms, _principal) do
    input_pattern = Path.join(frames_dir, @frame_pattern)
    fps_s = Integer.to_string(fps)
    crf_s = Integer.to_string(crf)

    # Structural argv. -y overwrite; image2 demuxer reads frame_%05d.png at -framerate fps; libx264 +
    # yuv420p (the universally-decodable pixel format) + faststart (moov atom up front for streaming);
    # optional mp3 -> AAC; -shortest so the muxed file ends with the shorter stream.
    base = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-framerate",
      fps_s,
      "-start_number",
      "0",
      "-i",
      input_pattern
    ]

    {audio_in, audio_codec} =
      case audio do
        nil -> {[], []}
        a -> {["-i", a], ["-c:a", "aac", "-b:a", "192k", "-shortest"]}
      end

    video_codec = [
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-crf",
      crf_s,
      "-preset",
      "medium",
      "-r",
      fps_s,
      "-movflags",
      "+faststart"
    ]

    argv = base ++ audio_in ++ video_codec ++ audio_codec ++ [out]

    # Wall-clock cap: run ffmpeg in a Task, kill the OS process group if it overruns. System.cmd blocks, so
    # the timeout is enforced by shutting the Task (the port closes -> ffmpeg gets SIGKILL).
    task =
      Task.async(fn ->
        System.cmd("ffmpeg", argv, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        Workbooks.BrokerAudit.record(:encode, :allow, nil, out)

        Logger.info(
          "wb-broker: ENCODE ok — #{frame_count} frames @ #{fps}fps#{if audio, do: " +audio", else: ""} -> #{out}"
        )

        {:ok, out}

      {:ok, {output, code}} ->
        deny(:ffmpeg_failed, out)
        Logger.warning("wb-broker: ffmpeg exit #{code} — #{String.slice(output, 0, 500)}")
        {:error, {:ffmpeg_failed, code}}

      nil ->
        deny(:encode_timeout, out)
        {:error, :encode_timeout}
    end
  end

  # ── audit / wire ─────────────────────────────────────────────────────────────

  defp deny(reason, target) do
    Workbooks.BrokerAudit.record(:encode, :deny, reason_atom(reason), target)
    Logger.warning("wb-broker: DENY encode — #{inspect(reason)}")
  end

  defp reason_atom(r) when is_atom(r), do: r
  defp reason_atom({r, _}), do: r
  defp reason_atom(_), do: :error

  defp target_of(frames_dir, out_path), do: "#{frames_dir} -> #{out_path}"

  @doc """
  Parse the wire request a guest writes for the `host_ffmpeg_encode` Dock import. Length-prefixed,
  little-endian (wasm32 LE), so paths with arbitrary bytes are unambiguous:

      [frames_len:u32][frames_dir][out_len:u32][out_path][audio_len:u32][audio_path][fps:u32][crf:u32]

  An empty audio_path (audio_len=0) means "no audio". Returns
  `{:ok, frames_dir, out_path, audio_or_nil, fps, crf}` | `:error`.
  """
  def parse_request(bin) when is_binary(bin) do
    with <<flen::little-32, frames::binary-size(flen), olen::little-32, out::binary-size(olen),
           alen::little-32, audio::binary-size(alen), fps::little-32, crf::little-32,
           _trailing::binary>> <- bin do
      audio_opt = if alen == 0, do: nil, else: audio
      {:ok, frames, out, audio_opt, fps, crf}
    else
      _ -> :error
    end
  end

  def parse_request(_), do: :error
end
