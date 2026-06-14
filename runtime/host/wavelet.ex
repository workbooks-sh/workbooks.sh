defmodule Workbooks.Wavelet do
  @moduledoc """
  The `wavelet` agent toolkit command (Phase 3). Makes the carved render-core
  usable by a bash-only WASM tenant as ONE command — `wavelet render
  <composition.html> -o <out.mp4> [--fps --w --h --duration]`.

  Two halves, joined here:

    1. RENDER (in-sandbox). The render core is `wavelet-render-core`'s `render_seq`
       binary compiled to `wasm32-wasip1` — a deterministic CSS-animation
       rasterizer (Blitz HTML/CSS + Stylo timeline + Vello CPU) that paints a
       composition to `frame_%05d.png`. It is registered as a CommandRegistry
       command (`#{inspect("wavelet-render-seq")}`) and run through the SAME generic
       `PackageManager.run` wasm lane as jq/grep — argv + WASI preopen, NO native
       exec, NO GPU. This is the "render the frame sequence IN-SANDBOX" step.

    2. ENCODE (in-guest, default). The PNG sequence → H.264/yuv420p mp4 (in-guest
       libx264, GPL — CRF 18/medium/high, broadcast quality) — and, when `--audio`
       is given, a native AAC audio track muxed alongside — is done ENTIRELY in the
       wasm guest by the Forge `ffmpeg` lane (`wb_encode.wasm`, libav*+libx264 under
       wasmtime, NO native exec). `Workbooks.WaveletEncode.encode/3`. A dependency-
       free `mpeg4` codec is available via `vcodec: "mpeg4"`. The host ffmpeg broker
       (`Workbooks.FfmpegBroker.encode/3`, `encode` Policy cap) is now only a legacy
       escape hatch (`encode_engine: :host`) — the in-guest lane matches its quality.

  Both halves operate inside ONE gated scratch root so: (a) the wasm only preopens
  that root (confined fs), and (b) the broker's path-gating accepts the frames dir
  + output because they live under the root. The composition and its sibling asset
  dir are copied into the scratch so relative `<img src="assets/…">` paths resolve
  in-sandbox exactly as `render_seq` expects.

  This REPLACES the old external `@work.books/wavelet-cli` (a native Node CLI)
  assumption: the agent authors an HTML composition and runs `wavelet render` —
  the whole pipeline is in-nexus (wasm render + brokered encode).
  """

  @render_command "wavelet-render-seq"
  @present_command "wavelet-render-present"
  @film_command "wavelet-render-film"

  # The render-core binary, compiled to wasm32-wasip1. Built from the wavelet
  # submodule (crates/wavelet-render-core, bin render_seq) by its release build;
  # we content-address + register it on first use. Resolved relative to this file
  # so it works from the repo and from a release where the submodule ships.
  @render_seq_wasm Path.expand(
                     "../wavelet/crates/wavelet-render-core/target/wasm32-wasip1/release/render_seq.wasm",
                     __DIR__
                   )

  # The presentation-export binary (bin render_present). Renders each SCENE of a
  # multi-scene composition to a full-bleed slide PNG then assembles a valid OOXML
  # .pptx ZIP — ENTIRELY in-guest (pure-Rust `zip`, NO ffmpeg/native exec). Same
  # submodule build output, content-addressed + registered on first use.
  @render_present_wasm Path.expand(
                         "../wavelet/crates/wavelet-render-core/target/wasm32-wasip1/release/render_present.wasm",
                         __DIR__
                       )

  # The film binary (bin render_film). Turns a workbook EDIT-STATE timeline.json
  # into a deterministic `frame_%05d.png` sequence — one full-bleed scene per edit
  # step with its `label` composited as an on-screen caption and a crossfade cut
  # between steps — all in-guest (Blitz/Stylo/Vello-CPU paint + CPU blend, NO
  # ffmpeg/native exec). Same submodule build output; content-addressed +
  # registered on first use; the existing ffmpeg lane encodes the frames → mp4.
  @render_film_wasm Path.expand(
                      "../wavelet/crates/wavelet-render-core/target/wasm32-wasip1/release/render_film.wasm",
                      __DIR__
                    )

  @default_present_frame 0
  @default_crossfade 0.4

  @default_w 1280
  @default_h 720
  @default_fps 30
  @default_duration 2.0

  # Bounds on the render intent (defense-in-depth on top of the broker's own
  # numeric gating). Dims are bounded so a guest cannot ask for an absurd canvas
  # that explodes host memory in the rasterizer; fps/duration shape frame count.
  @min_dim 16
  @max_dim 7680
  @min_fps 1
  @max_fps 240
  @max_duration 600.0

  @doc "The CommandRegistry name the render-core wasm is registered under."
  def render_command, do: @render_command

  @doc "The CommandRegistry name the presentation-export wasm is registered under."
  def present_command, do: @present_command

  @doc "The CommandRegistry name the film wasm is registered under."
  def film_command, do: @film_command

  @doc "The path to the film wasm artifact (submodule build output)."
  def render_film_wasm, do: @render_film_wasm

  @doc "The path to the render-core wasm artifact (submodule build output)."
  def render_seq_wasm, do: @render_seq_wasm

  @doc "The path to the presentation-export wasm artifact (submodule build output)."
  def render_present_wasm, do: @render_present_wasm

  @doc """
  Register the render-core wasm as a CommandRegistry command (idempotent). It is
  content-addressed into build/commands/ and bound under `#{@render_command}` with
  `:argv` mode (the universal CLI ABI render_seq uses). Returns {:ok, name} |
  {:error, reason}. A no-op (already registered) returns {:ok, name}.
  """
  def ensure_registered do
    case Workbooks.CommandRegistry.current(@render_command) do
      nil ->
        cond do
          not File.regular?(@render_seq_wasm) ->
            {:error, {:render_core_missing, @render_seq_wasm}}

          true ->
            case Workbooks.CommandRegistry.register_artifact(@render_command, @render_seq_wasm, :argv) do
              {:ok, _addressed} -> {:ok, @render_command}
              {:error, reason} -> {:error, reason}
            end
        end

      _spec ->
        {:ok, @render_command}
    end
  end

  @doc """
  Register the presentation-export wasm as a CommandRegistry command (idempotent).
  Content-addressed + bound under `#{@present_command}` with `:argv` mode. Returns
  {:ok, name} | {:error, reason}.
  """
  def ensure_present_registered do
    case Workbooks.CommandRegistry.current(@present_command) do
      nil ->
        cond do
          not File.regular?(@render_present_wasm) ->
            {:error, {:render_present_missing, @render_present_wasm}}

          true ->
            case Workbooks.CommandRegistry.register_artifact(
                   @present_command,
                   @render_present_wasm,
                   :argv
                 ) do
              {:ok, _addressed} -> {:ok, @present_command}
              {:error, reason} -> {:error, reason}
            end
        end

      _spec ->
        {:ok, @present_command}
    end
  end

  @doc """
  Register the film wasm as a CommandRegistry command (idempotent). Content-
  addressed + bound under `#{@film_command}` with `:argv` mode. Returns
  {:ok, name} | {:error, reason}.
  """
  def ensure_film_registered do
    case Workbooks.CommandRegistry.current(@film_command) do
      nil ->
        cond do
          not File.regular?(@render_film_wasm) ->
            {:error, {:render_film_missing, @render_film_wasm}}

          true ->
            case Workbooks.CommandRegistry.register_artifact(
                   @film_command,
                   @render_film_wasm,
                   :argv
                 ) do
              {:ok, _addressed} -> {:ok, @film_command}
              {:error, reason} -> {:error, reason}
            end
        end

      _spec ->
        {:ok, @film_command}
    end
  end

  @doc """
  The `wavelet` command entry point: a CLI-style argv dispatcher a bash-only tenant
  drives. `argv` is the token list AFTER the command name, e.g.
  `["render", "clip.html", "-o", "out.mp4", "--fps", "24"]`.

  Verbs:
    * `render <composition.html> -o <out.mp4> [--fps N] [--w N] [--h N] [--duration SECS] [--crf N] [--audio mp3]`
    * `audio <in.{mp3,aac,wav,m4a}> -o <out.m4a> [--bitrate KBPS]` — AUDIO-ONLY:
      no frames, no video; decode → native AAC → `.m4a`, entirely in the wasm guest.
    * `present <composition.html> -o <out.pptx> [--w N] [--h N] [--frame N] [--fps N]` —
      PRESENTATION export: one full-bleed slide per scene, assembled as a valid
      OOXML `.pptx` ENTIRELY in-guest (pure-Rust zip; NO ffmpeg, NO native exec).
    * `film <timeline.json> -o <out.mp4> [--w N] [--h N] [--fps N] [--crossfade SECS] [--audio mp3]` —
      IN-NEXUS WORKBOOK FILMING: an ordered list of workbook EDIT-STATE snapshots
      (each `{snapshot_html|snapshot_file, label, hold_secs}`) becomes a demo video
      — each snapshot played full-bleed as a scene with its `label` as an on-screen
      caption and a tasteful crossfade cut between steps. Frames rendered in-guest,
      then encoded to mp4 via the existing in-guest ffmpeg lane (`--audio` muxes a
      narration track). NO host browser, NO native exec.

  Returns {:ok, out_path} | {:error, reason}. `opts` threads non-argv concerns
  (`:allow` for the encode cap, `:principal`, `:rate`, `:roots`, `:timeout_ms`).
  """
  def command(argv, opts \\ []) when is_list(argv) do
    case argv do
      ["render" | rest] -> render(rest, opts)
      ["audio" | rest] -> audio(rest, opts)
      ["present" | rest] -> present(rest, opts)
      ["film" | rest] -> film(rest, opts)
      [verb | _] -> {:error, {:unknown_verb, verb}}
      [] -> {:error, :no_verb}
    end
  end

  @doc """
  `wavelet present <composition.html> -o <out.pptx> [--w N] [--h N] [--frame N] [--fps N]`.

  PRESENTATION export: a multi-scene composition becomes a PowerPoint `.pptx`
  deck — ONE full-bleed slide per scene — rendered ENTIRELY in-guest. Each scene
  is isolated + painted to a PNG by the render-core wasm, then a valid OOXML
  `.pptx` ZIP is assembled (pure-Rust `zip`), all inside the wasm sandbox: NO
  ffmpeg, NO native exec, NO GPU, NO broker grant. `argv` is the verb's tokens.

  Scene convention (matches the render-core): elements with a `data-scene`
  attribute (any tag) → else top-level `<section>` elements → else the whole doc
  is one scene. `--frame`/`--fps` seek the CSS timeline for the per-slide still.

  `opts`:
    * `:roots` — scratch-root allow-list for the wasm preopen. Defaults to
      `Workbooks.FfmpegBroker.default_roots/0`.
    * `:timeout_ms` — wall-clock cap on the render.

  Returns {:ok, out_path} | {:error, reason}.
  """
  def present(argv, opts \\ []) when is_list(argv) do
    with {:ok, p} <- parse_present_args(argv),
         :ok <- validate_present(p),
         {:ok, _name} <- ensure_present_registered() do
      run_present_pipeline(p, opts)
    end
  end

  @doc """
  `wavelet film <timeline.json> -o <out.mp4> [--w N] [--h N] [--fps N] [--crossfade SECS] [--audio mp3]`.

  IN-NEXUS WORKBOOK FILMING. Turns a sequence of workbook EDIT STATES into a demo
  video, entirely in-nexus (no host browser). `timeline.json` is an ordered list of
  steps — each `{snapshot_html (inline) | snapshot_file (a sandbox-relative ref),
  label, hold_secs}`. Each snapshot is played FULL-BLEED as a scene with its
  `label` composited as an on-screen caption; a tasteful crossfade cuts between
  steps. The frame sequence is rendered IN-GUEST by the film wasm (Blitz/Stylo/
  Vello-CPU paint + CPU blend, NO native exec/GPU), then encoded to an mp4 via the
  SAME in-guest ffmpeg lane as `render` (`--audio` muxes a narration track).

  `argv` is the verb's tokens. `opts`:
    * `:roots` — scratch-root allow-list (wasm preopen + encode). Default
      `Workbooks.FfmpegBroker.default_roots/0`.
    * `:timeout_ms` — wall-clock cap on the render.
    * `:encode_engine` / `:vcodec` — passed through to the encode (default in-guest
      H.264), matching `render`.

  `snapshot_file` refs in the timeline are resolved relative to the timeline's
  directory and staged into the sandbox alongside it, so a snapshot's own relative
  `<img>` assets resolve exactly as a standalone composition.

  Returns {:ok, out_path} | {:error, reason}.
  """
  def film(argv, opts \\ []) when is_list(argv) do
    with {:ok, p} <- parse_film_args(argv),
         :ok <- validate_film(p),
         {:ok, _name} <- ensure_film_registered() do
      run_film_pipeline(p, opts)
    end
  end

  # ── film argv parsing + validation ────────────────────────────────────────────

  defp parse_film_args(argv) do
    parse_film_args(argv, %{
      timeline: nil,
      out: nil,
      w: @default_w,
      h: @default_h,
      fps: @default_fps,
      crossfade: @default_crossfade,
      audio: nil
    })
  end

  defp parse_film_args([], acc), do: {:ok, acc}

  defp parse_film_args([flag, val | rest], acc) when flag in ["-o", "--out", "--output"],
    do: parse_film_args(rest, %{acc | out: val})

  defp parse_film_args([flag, val | rest], acc) when flag == "--w",
    do: with_film_int(val, :w, acc, rest)

  defp parse_film_args([flag, val | rest], acc) when flag == "--h",
    do: with_film_int(val, :h, acc, rest)

  defp parse_film_args([flag, val | rest], acc) when flag == "--fps",
    do: with_film_int(val, :fps, acc, rest)

  defp parse_film_args([flag, val | rest], acc) when flag == "--crossfade",
    do: with_film_float(val, :crossfade, acc, rest)

  defp parse_film_args([flag, val | rest], acc) when flag == "--audio",
    do: parse_film_args(rest, %{acc | audio: val})

  defp parse_film_args(["-o"], _acc), do: {:error, {:flag_needs_value, "-o"}}

  defp parse_film_args([flag | _], _acc)
       when binary_part(flag, 0, min(2, byte_size(flag))) == "--",
       do: {:error, {:flag_needs_value, flag}}

  defp parse_film_args([pos | rest], %{timeline: nil} = acc),
    do: parse_film_args(rest, %{acc | timeline: pos})

  defp parse_film_args([pos | _rest], _acc), do: {:error, {:unexpected_arg, pos}}

  defp with_film_int(val, key, acc, rest) do
    case Integer.parse(val) do
      {n, ""} -> parse_film_args(rest, Map.put(acc, key, n))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp with_film_float(val, key, acc, rest) do
    case Float.parse(val) do
      {f, _} -> parse_film_args(rest, Map.put(acc, key, f))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp validate_film(p) do
    cond do
      is_nil(p.timeline) -> {:error, :missing_timeline}
      is_nil(p.out) -> {:error, :missing_output}
      not String.ends_with?(p.out, ".mp4") -> {:error, :output_not_mp4}
      p.w < @min_dim or p.w > @max_dim -> {:error, {:invalid, :w}}
      p.h < @min_dim or p.h > @max_dim -> {:error, {:invalid, :h}}
      p.fps < @min_fps or p.fps > @max_fps -> {:error, {:invalid, :fps}}
      p.crossfade < 0.0 or p.crossfade > 10.0 -> {:error, {:invalid, :crossfade}}
      true -> :ok
    end
  end

  # ── the film pipeline: stage timeline+snapshots → in-guest render → encode ─────
  #
  # Mirrors run_pipeline/2 (render verb): ONE gated scratch under the encode root
  # holds the staged timeline (+ its sibling snapshot files/assets) and the rendered
  # frames, confining BOTH the wasm preopen and the encode. The film wasm renders
  # the `frame_%05d.png` sequence; the existing in-guest ffmpeg lane encodes it.
  defp run_film_pipeline(p, opts) do
    roots = Keyword.get(opts, :roots, Workbooks.FfmpegBroker.default_roots())
    root = List.first(roots) || System.tmp_dir!()
    File.mkdir_p!(root)

    scratch = Path.join(root, "wavelet-film-#{:erlang.unique_integer([:positive])}")
    frames = Path.join(scratch, "frames")

    try do
      File.mkdir_p!(frames)
      gated_out = Path.join(scratch, "out.mp4")

      with {:ok, timeline_guest} <- stage_timeline(p.timeline, scratch),
           :ok <- render_film_frames(scratch, timeline_guest, p),
           {:ok, encoded} <- encode(frames, p, gated_out, roots, opts),
           {:ok, delivered} <- deliver(encoded, p.out) do
        {:ok, delivered}
      end
    after
      File.rm_rf(scratch)
    end
  end

  # Stage the timeline.json + its WHOLE directory (sibling snapshot HTML files and
  # their assets) into the scratch root so `snapshot_file` refs + relative `<img>`
  # paths resolve in-sandbox. Returns the timeline's guest path under /work.
  defp stage_timeline(timeline, scratch) do
    abs = Path.expand(timeline)

    cond do
      not File.regular?(abs) ->
        {:error, {:timeline_missing, timeline}}

      true ->
        src_dir = Path.dirname(abs)
        base = Path.basename(abs)

        case File.cp_r(src_dir, scratch) do
          {:ok, _} -> {:ok, "/work/#{base}"}
          {:error, reason, _} -> {:error, {:stage_failed, reason}}
        end
    end
  end

  # Run the film wasm through the generic CommandRegistry lane. Preopens the scratch
  # root at /work (read timeline + snapshots, write frames into /work/frames).
  defp render_film_frames(scratch, timeline_guest, p) do
    argv = [
      timeline_guest,
      "/work/frames",
      "--w",
      Integer.to_string(p.w),
      "--h",
      Integer.to_string(p.h),
      "--fps",
      Integer.to_string(p.fps),
      "--crossfade",
      float_arg(p.crossfade)
    ]

    dirs = ["#{Path.expand(scratch)}::/work"]
    ropts = [timeout_ms: 300_000, fuel: 500_000_000_000]

    case Workbooks.CommandRegistry.run_status(@film_command, "", argv, dirs, ropts) do
      {:ok, _out, 0} -> :ok
      {:ok, out, status} -> {:error, {:film_failed, status, String.slice(out, 0, 400)}}
      {:error, reason} -> {:error, {:film_failed, reason}}
    end
  end

  @doc """
  `wavelet audio <in.{mp3,aac,wav,m4a}> -o <out.m4a> [--bitrate KBPS]`.

  AUDIO-ONLY output: decode an audio file → native AAC → ISO-BMFF `.m4a`, with NO
  frames and NO video stream, ENTIRELY in the wasm guest via the same `wb_encode`
  ffmpeg lane (`Workbooks.WaveletEncode.encode_audio/3`). Transcode or extract —
  NO host ffmpeg, NO native exec, NO broker grant. `argv` is the verb's tokens.

  Returns {:ok, out_path} | {:error, reason}.
  """
  def audio(argv, opts \\ []) when is_list(argv) do
    with {:ok, p} <- parse_audio_args(argv),
         :ok <- validate_audio(p) do
      out_abs = Path.expand(p.out)

      Workbooks.WaveletEncode.encode_audio(p.in, out_abs,
        bitrate_kbps: p.bitrate,
        timeout_ms: Keyword.get(opts, :timeout_ms, 600_000)
      )
    end
  end

  defp parse_audio_args(argv), do: parse_audio_args(argv, %{in: nil, out: nil, bitrate: 128})

  defp parse_audio_args([], acc), do: {:ok, acc}

  defp parse_audio_args([flag, val | rest], acc) when flag in ["-o", "--out", "--output"],
    do: parse_audio_args(rest, %{acc | out: val})

  defp parse_audio_args([flag, val | rest], acc) when flag == "--bitrate",
    do: with_audio_int(val, :bitrate, acc, rest)

  defp parse_audio_args(["-o"], _acc), do: {:error, {:flag_needs_value, "-o"}}

  defp parse_audio_args([flag | _], _acc)
       when binary_part(flag, 0, min(2, byte_size(flag))) == "--",
       do: {:error, {:flag_needs_value, flag}}

  defp parse_audio_args([pos | rest], %{in: nil} = acc),
    do: parse_audio_args(rest, %{acc | in: pos})

  defp parse_audio_args([pos | _rest], _acc), do: {:error, {:unexpected_arg, pos}}

  defp with_audio_int(val, key, acc, rest) do
    case Integer.parse(val) do
      {n, ""} -> parse_audio_args(rest, Map.put(acc, key, n))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp validate_audio(p) do
    cond do
      is_nil(p.in) -> {:error, :missing_audio_input}
      is_nil(p.out) -> {:error, :missing_output}
      not String.ends_with?(p.out, ".m4a") -> {:error, :output_not_m4a}
      p.bitrate < 8 or p.bitrate > 512 -> {:error, {:invalid, :bitrate}}
      true -> :ok
    end
  end

  # ── present (.pptx) argv parsing + validation ─────────────────────────────────

  defp parse_present_args(argv) do
    parse_present_args(argv, %{
      comp: nil,
      out: nil,
      w: @default_w,
      h: @default_h,
      frame: @default_present_frame,
      fps: @default_fps
    })
  end

  defp parse_present_args([], acc), do: {:ok, acc}

  defp parse_present_args([flag, val | rest], acc) when flag in ["-o", "--out", "--output"],
    do: parse_present_args(rest, %{acc | out: val})

  defp parse_present_args([flag, val | rest], acc) when flag == "--w",
    do: with_present_int(val, :w, acc, rest)

  defp parse_present_args([flag, val | rest], acc) when flag == "--h",
    do: with_present_int(val, :h, acc, rest)

  defp parse_present_args([flag, val | rest], acc) when flag == "--frame",
    do: with_present_int(val, :frame, acc, rest)

  defp parse_present_args([flag, val | rest], acc) when flag == "--fps",
    do: with_present_int(val, :fps, acc, rest)

  defp parse_present_args(["-o"], _acc), do: {:error, {:flag_needs_value, "-o"}}

  defp parse_present_args([flag | _], _acc)
       when binary_part(flag, 0, min(2, byte_size(flag))) == "--",
       do: {:error, {:flag_needs_value, flag}}

  defp parse_present_args([pos | rest], %{comp: nil} = acc),
    do: parse_present_args(rest, %{acc | comp: pos})

  defp parse_present_args([pos | _rest], _acc), do: {:error, {:unexpected_arg, pos}}

  defp with_present_int(val, key, acc, rest) do
    case Integer.parse(val) do
      {n, ""} -> parse_present_args(rest, Map.put(acc, key, n))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp validate_present(p) do
    cond do
      is_nil(p.comp) -> {:error, :missing_composition}
      is_nil(p.out) -> {:error, :missing_output}
      not String.ends_with?(p.out, ".pptx") -> {:error, :output_not_pptx}
      p.w < @min_dim or p.w > @max_dim -> {:error, {:invalid, :w}}
      p.h < @min_dim or p.h > @max_dim -> {:error, {:invalid, :h}}
      p.fps < @min_fps or p.fps > @max_fps -> {:error, {:invalid, :fps}}
      p.frame < 0 -> {:error, {:invalid, :frame}}
      true -> :ok
    end
  end

  # ── the present pipeline: in-sandbox render scenes → assemble pptx → deliver ───
  #
  # ALL in-guest: the render_present wasm renders each scene to a PNG and assembles
  # the .pptx ZIP itself (pure-Rust zip), so there is NO encode step, NO ffmpeg, NO
  # broker grant. We only stage the composition into a gated scratch (so the wasm
  # preopen is confined + relative assets resolve) and deliver the output.
  defp run_present_pipeline(p, opts) do
    roots = Keyword.get(opts, :roots, Workbooks.FfmpegBroker.default_roots())
    root = List.first(roots) || System.tmp_dir!()
    File.mkdir_p!(root)

    scratch = Path.join(root, "wavelet-present-#{:erlang.unique_integer([:positive])}")

    try do
      File.mkdir_p!(scratch)
      gated_out = Path.join(scratch, "out.pptx")

      with {:ok, comp_guest} <- stage_composition(p.comp, scratch),
           :ok <- render_present_pptx(scratch, comp_guest, p, opts),
           {:ok, delivered} <- deliver(gated_out, p.out) do
        {:ok, delivered}
      end
    after
      File.rm_rf(scratch)
    end
  end

  # Run the presentation-export wasm through the generic CommandRegistry lane.
  # Preopens the scratch root at /work (read composition + assets, write the
  # .pptx). render_present writes the deck to /work/out.pptx.
  defp render_present_pptx(scratch, comp_guest, p, opts \\ []) do
    argv = [
      comp_guest,
      "/work/out.pptx",
      "--w",
      Integer.to_string(p.w),
      "--h",
      Integer.to_string(p.h),
      "--frame",
      Integer.to_string(p.frame),
      "--fps",
      Integer.to_string(p.fps)
    ]

    dirs = ["#{Path.expand(scratch)}::/work"]

    # Rendering N scenes is CPU-heavy; grant the same generous ceilings as the
    # frame-sequence render.
    ropts = [timeout_ms: Keyword.get(opts, :timeout_ms, 300_000), fuel: 500_000_000_000]

    case Workbooks.CommandRegistry.run_status(@present_command, "", argv, dirs, ropts) do
      {:ok, _out, 0} -> :ok
      {:ok, out, status} -> {:error, {:present_failed, status, String.slice(out, 0, 400)}}
      {:error, reason} -> {:error, {:present_failed, reason}}
    end
  end

  @doc """
  `wavelet render <composition.html> -o <out.mp4> [flags]`.

  Renders the composition to a deterministic frame sequence IN-SANDBOX (the
  render-core wasm command) then muxes it to an h264 mp4 via the host ffmpeg encode
  broker. `argv` is the render verb's tokens; `opts`:

    * `:allow` (bool, REQUIRED for encode — default-deny; derive from the `encode`
      Policy cap). Without it the encode broker refuses with `:denied`.
    * `:principal` / `:rate` — revocation + rate quota threaded into the broker.
    * `:roots` — path-gating allow-list for the broker AND the wasm preopen scratch
      parent. Defaults to `Workbooks.FfmpegBroker.default_roots/0`.
    * `:timeout_ms` — wall-clock cap on the encode.

  Returns {:ok, out_path} | {:error, reason}.
  """
  def render(argv, opts \\ []) when is_list(argv) do
    with {:ok, p} <- parse_render_args(argv),
         :ok <- validate_render(p),
         {:ok, _name} <- ensure_registered() do
      run_pipeline(p, opts)
    end
  end

  # ── argv parsing ────────────────────────────────────────────────────────────

  defp parse_render_args(argv) do
    parse_render_args(argv, %{
      comp: nil,
      out: nil,
      w: @default_w,
      h: @default_h,
      fps: @default_fps,
      duration: @default_duration,
      crf: nil,
      audio: nil
    })
  end

  defp parse_render_args([], acc), do: {:ok, acc}

  defp parse_render_args([flag, val | rest], acc) when flag in ["-o", "--out", "--output"],
    do: parse_render_args(rest, %{acc | out: val})

  defp parse_render_args([flag, val | rest], acc) when flag == "--fps",
    do: with_int(val, :fps, acc, rest)

  defp parse_render_args([flag, val | rest], acc) when flag == "--w",
    do: with_int(val, :w, acc, rest)

  defp parse_render_args([flag, val | rest], acc) when flag == "--h",
    do: with_int(val, :h, acc, rest)

  defp parse_render_args([flag, val | rest], acc) when flag == "--crf",
    do: with_int(val, :crf, acc, rest)

  defp parse_render_args([flag, val | rest], acc) when flag == "--duration",
    do: with_float(val, :duration, acc, rest)

  defp parse_render_args([flag, val | rest], acc) when flag == "--audio",
    do: parse_render_args(rest, %{acc | audio: val})

  defp parse_render_args(["-o"], _acc), do: {:error, {:flag_needs_value, "-o"}}

  defp parse_render_args([flag | _], _acc) when binary_part(flag, 0, min(2, byte_size(flag))) == "--",
    do: {:error, {:flag_needs_value, flag}}

  # A bare positional → the composition (first positional wins; a second is an error).
  defp parse_render_args([pos | rest], %{comp: nil} = acc),
    do: parse_render_args(rest, %{acc | comp: pos})

  defp parse_render_args([pos | _rest], _acc), do: {:error, {:unexpected_arg, pos}}

  defp with_int(val, key, acc, rest) do
    case Integer.parse(val) do
      {n, ""} -> parse_render_args(rest, Map.put(acc, key, n))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp with_float(val, key, acc, rest) do
    case Float.parse(val) do
      {f, ""} -> parse_render_args(rest, Map.put(acc, key, f))
      {f, _} -> parse_render_args(rest, Map.put(acc, key, f))
      _ -> {:error, {:invalid, key}}
    end
  end

  defp validate_render(p) do
    cond do
      is_nil(p.comp) -> {:error, :missing_composition}
      is_nil(p.out) -> {:error, :missing_output}
      not String.ends_with?(p.out, ".mp4") -> {:error, :output_not_mp4}
      p.w < @min_dim or p.w > @max_dim -> {:error, {:invalid, :w}}
      p.h < @min_dim or p.h > @max_dim -> {:error, {:invalid, :h}}
      p.fps < @min_fps or p.fps > @max_fps -> {:error, {:invalid, :fps}}
      p.duration <= 0.0 or p.duration > @max_duration -> {:error, {:invalid, :duration}}
      true -> :ok
    end
  end

  # ── the pipeline: in-sandbox render → host encode ─────────────────────────────

  defp run_pipeline(p, opts) do
    roots = Keyword.get(opts, :roots, Workbooks.FfmpegBroker.default_roots())
    root = List.first(roots) || System.tmp_dir!()
    File.mkdir_p!(root)

    # One gated scratch under the encode root: holds the staged composition + assets
    # and the rendered frames. Confines BOTH the wasm preopen and the broker path-gate.
    scratch = Path.join(root, "wavelet-#{:erlang.unique_integer([:positive])}")
    frames = Path.join(scratch, "frames")

    try do
      File.mkdir_p!(frames)

      # Encode into a GATED temp under the root (the broker refuses any out path
      # outside its roots), then deliver to the caller's requested path. This lets
      # the user name an output anywhere the host can write while the broker stays
      # confined to its scratch root.
      gated_out = Path.join(scratch, "out.mp4")

      with {:ok, comp_guest} <- stage_composition(p.comp, scratch),
           :ok <- render_frames(scratch, comp_guest, frames, p),
           {:ok, encoded} <- encode(frames, p, gated_out, roots, opts),
           {:ok, delivered} <- deliver(encoded, p.out) do
        {:ok, delivered}
      end
    after
      File.rm_rf(scratch)
    end
  end

  # Stage the composition + its sibling asset dir into the scratch so relative
  # `assets/…` references resolve in-sandbox. Returns the composition's guest path
  # (relative to the preopened scratch root, mounted at /work).
  defp stage_composition(comp, scratch) do
    comp_abs = Path.expand(comp)

    cond do
      not File.regular?(comp_abs) ->
        {:error, {:composition_missing, comp}}

      true ->
        src_dir = Path.dirname(comp_abs)
        base = Path.basename(comp_abs)
        # Copy the whole composition directory (the html + any sibling assets/) into
        # the scratch root. Relative asset paths inside the html then resolve against
        # the same layout the FileNetProvider expects.
        case File.cp_r(src_dir, scratch) do
          {:ok, _} -> {:ok, "/work/#{base}"}
          {:error, reason, _} -> {:error, {:stage_failed, reason}}
        end
    end
  end

  # Run the render-core wasm command through the generic CommandRegistry lane.
  # Preopens the scratch root at /work (read composition + assets, write frames).
  # render_seq writes frame_%05d.png into the out dir, which is /work/frames.
  defp render_frames(scratch, comp_guest, _frames, p) do
    argv = [
      comp_guest,
      "/work/frames",
      "--w",
      Integer.to_string(p.w),
      "--h",
      Integer.to_string(p.h),
      "--fps",
      Integer.to_string(p.fps),
      "--duration",
      float_arg(p.duration)
    ]

    dirs = ["#{Path.expand(scratch)}::/work"]

    # The render is CPU-heavy (rasterizes N frames); give it a generous wall-clock +
    # fuel ceiling vs the 30s/5e9 default so multi-second clips finish.
    ropts = [timeout_ms: 300_000, fuel: 500_000_000_000]

    case Workbooks.CommandRegistry.run_status(@render_command, "", argv, dirs, ropts) do
      {:ok, _out, 0} -> :ok
      {:ok, out, status} -> {:error, {:render_failed, status, String.slice(out, 0, 400)}}
      {:error, reason} -> {:error, {:render_failed, reason}}
    end
  end

  # Two encode engines:
  #   :in_guest (default) — Workbooks.WaveletEncode runs the Forge ffmpeg lane's
  #     wb_encode.wasm UNDER WASMTIME. H.264 (in-guest libx264, GPL) + native AAC
  #     AUDIO mux, NO native exec, NO broker grant. Broadcast quality (CRF 18,
  #     medium/high), matching the broker — so the broker is no longer needed for
  #     quality. Closes the wavelet mp4-encode bedrock gap INCLUDING H.264 + audio.
  #   :host — Workbooks.FfmpegBroker (native ffmpeg). LEGACY/escape hatch only; the
  #     in-guest lane now reaches the same quality. Default-deny via the `encode` cap.
  # Select with opts[:encode_engine]; :in_guest is the zero-trust default.
  defp encode(frames, p, gated_out, roots, opts) do
    out_abs = Path.expand(gated_out)
    engine = Keyword.get(opts, :encode_engine, :in_guest)

    if engine == :in_guest do
      Workbooks.WaveletEncode.encode(frames, out_abs,
        fps: p.fps,
        audio: p.audio,
        vcodec: Keyword.get(opts, :vcodec, "h264"),
        timeout_ms: Keyword.get(opts, :timeout_ms, 600_000)
      )
    else
      encode_host(frames, p, out_abs, roots, opts)
    end
  end

  defp encode_host(frames, p, out_abs, roots, opts) do
    with {:ok, gated_audio} <- stage_audio(p.audio, Path.dirname(frames)) do
      enc_opts =
        [
          allow: Keyword.get(opts, :allow, false),
          fps: p.fps,
          roots: roots
        ]
        |> maybe_put(:crf, p.crf)
        |> maybe_put(:audio, gated_audio)
        |> maybe_put(:principal, Keyword.get(opts, :principal))
        |> maybe_put(:rate, Keyword.get(opts, :rate))
        |> maybe_put(:timeout_ms, Keyword.get(opts, :timeout_ms))

      Workbooks.FfmpegBroker.encode(frames, out_abs, enc_opts)
    end
  end

  # Stage an optional audio file into the gated scratch so the broker's audio
  # path-gate accepts it (the source may live outside the encode root).
  defp stage_audio(nil, _scratch), do: {:ok, nil}

  defp stage_audio(path, scratch) do
    src = Path.expand(path)

    cond do
      not File.regular?(src) ->
        {:error, {:audio_missing, path}}

      true ->
        dest = Path.join(scratch, "audio" <> Path.extname(src))

        case File.cp(src, dest) do
          :ok -> {:ok, dest}
          {:error, reason} -> {:error, {:audio_stage_failed, reason}}
        end
    end
  end

  # Copy the gated mp4 to the caller's requested output path (which may live
  # outside the encode root — e.g. the agent's CWD). Done BEFORE the scratch is
  # torn down. Returns the delivered absolute path.
  defp deliver(encoded, out) do
    dest = Path.expand(out)
    File.mkdir_p!(Path.dirname(dest))

    case File.cp(encoded, dest) do
      :ok -> {:ok, dest}
      {:error, reason} -> {:error, {:deliver_failed, reason}}
    end
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  # render_seq parses --duration with f64::parse; emit a value it accepts (e.g. "2"
  # for 2.0 is fine, but keep a decimal to be unambiguous).
  defp float_arg(f) when is_float(f) do
    s = Float.to_string(f)
    s
  end

  defp float_arg(n) when is_integer(n), do: Integer.to_string(n) <> ".0"
end
