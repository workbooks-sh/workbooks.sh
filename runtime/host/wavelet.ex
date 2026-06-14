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

    2. ENCODE (host broker). ffmpeg cannot run in the wasm guest (no native exec =
       BEDROCK), so muxing the PNG sequence → h264/yuv420p mp4 is the one trusted
       host-service escape — `Workbooks.FfmpegBroker.encode/3` (Phase 2). The
       `encode` Policy cap gates it.

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

  # The render-core binary, compiled to wasm32-wasip1. Built from the wavelet
  # submodule (crates/wavelet-render-core, bin render_seq) by its release build;
  # we content-address + register it on first use. Resolved relative to this file
  # so it works from the repo and from a release where the submodule ships.
  @render_seq_wasm Path.expand(
                     "../wavelet/crates/wavelet-render-core/target/wasm32-wasip1/release/render_seq.wasm",
                     __DIR__
                   )

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

  @doc "The path to the render-core wasm artifact (submodule build output)."
  def render_seq_wasm, do: @render_seq_wasm

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
  The `wavelet` command entry point: a CLI-style argv dispatcher a bash-only tenant
  drives. `argv` is the token list AFTER the command name, e.g.
  `["render", "clip.html", "-o", "out.mp4", "--fps", "24"]`.

  Verbs:
    * `render <composition.html> -o <out.mp4> [--fps N] [--w N] [--h N] [--duration SECS] [--crf N] [--audio mp3]`

  Returns {:ok, out_path} | {:error, reason}. `opts` threads non-argv concerns
  (`:allow` for the encode cap, `:principal`, `:rate`, `:roots`, `:timeout_ms`).
  """
  def command(argv, opts \\ []) when is_list(argv) do
    case argv do
      ["render" | rest] -> render(rest, opts)
      [verb | _] -> {:error, {:unknown_verb, verb}}
      [] -> {:error, :no_verb}
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

  defp encode(frames, p, gated_out, roots, opts) do
    out_abs = Path.expand(gated_out)

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
