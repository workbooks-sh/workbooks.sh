defmodule Workbooks.WaveletCommandTest do
  @moduledoc """
  End-to-end proof of the Phase-3 `wavelet render` toolkit command: a bash-only
  tenant authors an HTML composition and runs ONE command that renders the frame
  sequence IN-SANDBOX (the render-core wasm via CommandRegistry) then muxes it to
  an mp4. The DEFAULT mux engine is :in_guest with DEFAULT codec H.264 — the Forge
  ffmpeg lane's wb_encode.wasm encodes H.264 (in-guest libx264) + AAC into mp4 UNDER
  WASMTIME (no host ffmpeg, no native exec, no broker grant); `vcodec: "mpeg4"` is a
  dependency-free in-guest fallback. The :host engine (native ffmpeg) is a legacy
  escape hatch and remains default-deny. Empirical — actually runs the wasm under
  wasmtime and shells ffprobe only to inspect, never faked.
  """
  use ExUnit.Case, async: false
  alias Workbooks.Wavelet

  @moduletag :wavelet
  @moduletag timeout: 600_000

  # A self-contained composition (no external assets) so staging is trivial and
  # the in-sandbox render is hermetic — an animated colored box on a dark bg.
  @composition """
  <!doctype html>
  <html><head><style>
    html,body{margin:0;padding:0;width:100%;height:100%;background:#0b1020;overflow:hidden}
    #box{position:absolute;left:20px;top:40px;width:120px;height:120px;background:#3fe081;
         animation:slide 1s linear infinite}
    @keyframes slide{from{transform:translateX(0)}to{transform:translateX(200px)}}
  </style></head><body><div id="box"></div></body></html>
  """

  defp probe(path, entry) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=#{entry}", "-of", "default=nw=1:nk=1", path],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  setup do
    unless System.find_executable("ffmpeg") && System.find_executable("ffprobe"),
      do: raise("ffmpeg/ffprobe required on PATH for the wavelet command test")

    unless File.regular?(Wavelet.render_seq_wasm()),
      do: raise("render-core wasm not built: #{Wavelet.render_seq_wasm()}")

    unless File.regular?(Wavelet.render_present_wasm()),
      do: raise("presentation-export wasm not built: #{Wavelet.render_present_wasm()}")

    unless File.regular?(Wavelet.render_film_wasm()),
      do: raise("film wasm not built: #{Wavelet.render_film_wasm()}")

    # A dedicated gated root for the encode broker AND the wasm preopen scratch.
    root = Path.join(System.tmp_dir!(), "wb_wavelet_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "ensure_registered binds the render-core wasm as a CommandRegistry command" do
    assert {:ok, name} = Wavelet.ensure_registered()
    assert name == Wavelet.render_command()
    # It is now a live registry entry, resolvable by name like jq/grep.
    assert {:wasm, path, :argv} = Workbooks.CommandRegistry.current(name)
    assert File.regular?(path)
    # idempotent
    assert {:ok, ^name} = Wavelet.ensure_registered()
  end

  test "wavelet render: in-sandbox frames -> IN-GUEST H.264 mp4 (default, no native exec)",
       %{root: root} do
    comp = Path.join(root, "clip.html")
    File.write!(comp, @composition)
    out = Path.join(root, "clip.mp4")

    # The exact bash-tenant command surface. The DEFAULT encode engine is :in_guest
    # and the DEFAULT video codec is H.264 via the in-guest libx264 lane: the mp4 mux
    # runs the Forge ffmpeg lane's wb_encode.wasm UNDER WASMTIME — no host ffmpeg, no
    # native exec, no broker grant (:allow not required for the in-guest path).
    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12", "--duration", "1"],
               roots: [root]
             )

    assert delivered == Path.expand(out)
    assert File.regular?(delivered)
    # mp4 magic: bytes 4..7 == "ftyp"
    assert <<_::32, "ftyp", _::binary>> = File.read!(delivered)
    # the in-guest encoder produced real H.264/yuv420p — matching the broker's quality
    assert probe(delivered, "codec_name") == "h264"
    assert probe(delivered, "pix_fmt") == "yuv420p"
    assert String.to_integer(probe(delivered, "nb_frames")) > 0
  end

  test "wavelet render vcodec: mpeg4 -> IN-GUEST mpeg4 fallback (dependency-free, no native exec)",
       %{root: root} do
    comp = Path.join(root, "clip_m4.html")
    File.write!(comp, @composition)
    out = Path.join(root, "clip_m4.mp4")

    # The dependency-free fallback codec, still fully in-guest (no broker grant).
    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12", "--duration", "1"],
               vcodec: "mpeg4",
               roots: [root]
             )

    assert File.regular?(delivered)
    assert probe(delivered, "codec_name") == "mpeg4"
    assert probe(delivered, "pix_fmt") == "yuv420p"
  end

  test "wavelet render encode_engine: :host -> brokered h264 mp4 (legacy escape hatch)",
       %{root: root} do
    comp = Path.join(root, "clip_h264.html")
    File.write!(comp, @composition)
    out = Path.join(root, "clip_h264.mp4")

    # Explicit :host engine selects the native ffmpeg broker (default-deny: needs the
    # encode grant via :allow). Kept as a legacy escape hatch — the in-guest lane now
    # reaches the same H.264 quality without native exec.
    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12", "--duration", "1"],
               allow: true,
               encode_engine: :host,
               roots: [root]
             )

    assert File.regular?(delivered)
    assert probe(delivered, "codec_name") == "h264"
    assert probe(delivered, "pix_fmt") == "yuv420p"
  end

  test "wavelet render --audio: muxes an mp3 as an aac track IN-GUEST (no broker)",
       %{root: root} do
    comp = Path.join(root, "av.html")
    File.write!(comp, @composition)
    mp3 = Path.join(root, "tone.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=2", mp3],
        stderr_to_stdout: true
      )

    out = Path.join(root, "av.mp4")

    # No `allow:` grant — audio now muxes ENTIRELY in the wasm guest (H.264 video +
    # native AAC), so it needs NO `encode` broker cap. This is the bedrock close.
    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12",
                "--duration", "2", "--audio", mp3],
               roots: [root]
             )

    # In-guest video codec is H.264 (the default libx264 lane), muxed alongside AAC.
    assert probe(delivered, "codec_name") == "h264"

    {a, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1:nk=1", delivered],
        stderr_to_stdout: true
      )

    assert String.trim(a) == "aac"
  end

  test "encode_engine: :host default-deny — the bedrock-escape mux refuses without the grant",
       %{root: root} do
    comp = Path.join(root, "deny.html")
    File.write!(comp, @composition)
    out = Path.join(root, "deny.mp4")

    # The :host broker is the bedrock escape (native ffmpeg) and stays default-deny:
    # no allow: true -> the mux is rejected. Frames were rendered in-sandbox first;
    # the cap gates only the native-exec escape. (The in-guest engine needs no grant —
    # there is no native exec to gate — see the default-engine test above.)
    assert {:error, :denied} =
             Wavelet.command(
               ["render", comp, "-o", out, "--fps", "12", "--duration", "1"],
               encode_engine: :host,
               roots: [root]
             )

    refute File.exists?(out)
  end

  test "wavelet audio: mp3 -> AUDIO-ONLY .m4a (AAC, no video, in-guest, no broker)",
       %{root: root} do
    mp3 = Path.join(root, "src.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=2", mp3],
        stderr_to_stdout: true
      )

    out = Path.join(root, "out.m4a")

    # The bash-tenant audio-only surface: NO frames, NO video, NO broker grant.
    # The whole decode->AAC->mp4 mux runs in the wasm guest (wb_encode `audio` mode).
    assert {:ok, delivered} =
             Wavelet.command(["audio", mp3, "-o", out, "--bitrate", "192"], roots: [root])

    assert delivered == Path.expand(out)
    assert File.regular?(delivered)
    # ISO-BMFF magic: bytes 4..7 == "ftyp"
    assert <<_::32, "ftyp", _::binary>> = File.read!(delivered)

    # audio stream is AAC...
    {a, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1:nk=1", delivered],
        stderr_to_stdout: true
      )

    assert String.trim(a) == "aac"

    # ...and there is NO video stream (audio-only).
    {v, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1:nk=1", delivered],
        stderr_to_stdout: true
      )

    assert String.trim(v) == ""
  end

  test "wavelet audio: wav -> .m4a transcode (extract/convert)", %{root: root} do
    wav = Path.join(root, "src.wav")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "sine=frequency=330:duration=1", wav],
        stderr_to_stdout: true
      )

    out = Path.join(root, "from_wav.m4a")

    assert {:ok, delivered} = Wavelet.command(["audio", wav, "-o", out], roots: [root])
    assert File.regular?(delivered)

    {a, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1:nk=1", delivered],
        stderr_to_stdout: true
      )

    assert String.trim(a) == "aac"
  end

  test "wavelet audio argv validation: bad ext, missing input/output, bad bitrate",
       %{root: root} do
    mp3 = Path.join(root, "v.mp3")
    File.write!(mp3, "stub")

    assert {:error, :output_not_m4a} = Wavelet.audio([mp3, "-o", Path.join(root, "x.mp3")])
    assert {:error, :missing_output} = Wavelet.audio([mp3])
    assert {:error, :missing_audio_input} = Wavelet.audio(["-o", Path.join(root, "x.m4a")])
    assert {:error, {:invalid, :bitrate}} = Wavelet.audio([mp3, "-o", Path.join(root, "x.m4a"), "--bitrate", "9999"])
  end

  test "wavelet audio: missing input file is refused", %{root: root} do
    out = Path.join(root, "nope.m4a")
    assert {:error, {:audio_missing, _}} = Wavelet.audio(["/nonexistent/a.mp3", "-o", out])
  end

  test "missing composition is refused before any work", %{root: root} do
    out = Path.join(root, "nope.mp4")

    assert {:error, {:composition_missing, _}} =
             Wavelet.render(["/nonexistent/clip.html", "-o", out], allow: true, roots: [root])
  end

  test "argv validation: bad output extension and missing flags", %{root: root} do
    comp = Path.join(root, "v.html")
    File.write!(comp, @composition)

    assert {:error, :output_not_mp4} =
             Wavelet.render([comp, "-o", Path.join(root, "x.webm")], allow: true, roots: [root])

    assert {:error, :missing_output} = Wavelet.render([comp], allow: true, roots: [root])
    assert {:error, {:invalid, :fps}} = Wavelet.render([comp, "-o", Path.join(root, "x.mp4"), "--fps", "abc"], roots: [root])
  end

  test "unknown verb is refused" do
    assert {:error, {:unknown_verb, "frobnicate"}} = Wavelet.command(["frobnicate"])
    assert {:error, :no_verb} = Wavelet.command([])
  end

  # ── present (.pptx) export ──────────────────────────────────────────────────

  # A multi-scene composition: three top-level <section>s with distinct solid
  # backgrounds -> one full-bleed slide per scene.
  @deck """
  <!doctype html>
  <html><head><style>
    html,body{margin:0;padding:0;width:100%;height:100%}
    section{position:absolute;inset:0}
    .a{background:#3fe081}.b{background:#149157}.c{background:#0b1020}
    h1{color:#fff;font-family:sans-serif;font-size:40px;margin:30px}
  </style></head><body>
    <section class="a"><h1>One</h1></section>
    <section class="b"><h1>Two</h1></section>
    <section class="c"><h1>Three</h1></section>
  </body></html>
  """

  # Names inside the pptx zip (Erlang :zip yields charlists).
  defp pptx_names(path) do
    {:ok, list} = :zip.list_dir(String.to_charlist(path))

    for {:zip_file, name, _info, _comment, _offset, _comp} <- list,
        do: List.to_string(name)
  end

  test "ensure_present_registered binds the presentation-export wasm as a command" do
    assert {:ok, name} = Wavelet.ensure_present_registered()
    assert name == Wavelet.present_command()
    assert {:wasm, path, :argv} = Workbooks.CommandRegistry.current(name)
    assert File.regular?(path)
    assert {:ok, ^name} = Wavelet.ensure_present_registered()
  end

  test "wavelet present: multi-scene composition -> valid .pptx, one slide per scene (in-guest)",
       %{root: root} do
    comp = Path.join(root, "deck.html")
    File.write!(comp, @deck)
    out = Path.join(root, "deck.pptx")

    # The bash-tenant present surface — ALL in-guest (render scenes -> assemble
    # pptx), NO ffmpeg, NO native exec, NO broker grant (no allow: needed).
    assert {:ok, delivered} =
             Wavelet.command(
               ["present", comp, "-o", out, "--w", "320", "--h", "180"],
               roots: [root]
             )

    assert delivered == Path.expand(out)
    assert File.regular?(delivered)
    # OOXML/zip magic: starts with "PK\x03\x04".
    assert <<"PK", 3, 4, _::binary>> = File.read!(delivered)

    names = pptx_names(delivered)

    # Required OOXML parts.
    for required <- [
          "[Content_Types].xml",
          "_rels/.rels",
          "ppt/presentation.xml",
          "ppt/_rels/presentation.xml.rels",
          "ppt/slideMasters/slideMaster1.xml",
          "ppt/slideLayouts/slideLayout1.xml",
          "ppt/theme/theme1.xml"
        ] do
      assert required in names, "pptx missing part: #{required}"
    end

    # THREE scenes -> three slides + three media images.
    for i <- 1..3 do
      assert "ppt/slides/slide#{i}.xml" in names
      assert "ppt/slides/_rels/slide#{i}.xml.rels" in names
      assert "ppt/media/image#{i}.png" in names
    end

    # ...and no phantom 4th slide.
    refute "ppt/slides/slide4.xml" in names

    # The three slide images are genuinely different scenes (distinct backgrounds),
    # so their PNG bytes must differ.
    read = fn name ->
      {:ok, [{_n, bytes}]} =
        :zip.extract(String.to_charlist(delivered),
          [:memory, {:file_list, [String.to_charlist(name)]}]
        )

      bytes
    end

    i1 = read.("ppt/media/image1.png")
    i2 = read.("ppt/media/image2.png")
    i3 = read.("ppt/media/image3.png")
    assert i1 != i2, "scene 1 and 2 rendered identically — isolation failed"
    assert i2 != i3, "scene 2 and 3 rendered identically — isolation failed"
  end

  test "wavelet present: a single-section/no-section doc -> a one-slide deck",
       %{root: root} do
    comp = Path.join(root, "one.html")
    # No <section>, no data-scene -> the whole doc is ONE scene.
    File.write!(comp, @composition)
    out = Path.join(root, "one.pptx")

    assert {:ok, delivered} =
             Wavelet.command(["present", comp, "-o", out, "--w", "320", "--h", "180"],
               roots: [root]
             )

    names = pptx_names(delivered)
    assert "ppt/slides/slide1.xml" in names
    refute "ppt/slides/slide2.xml" in names
  end

  test "wavelet present argv validation: bad ext, missing input/output, bad dim",
       %{root: root} do
    comp = Path.join(root, "p.html")
    File.write!(comp, @deck)

    assert {:error, :output_not_pptx} =
             Wavelet.present([comp, "-o", Path.join(root, "x.key")], roots: [root])

    assert {:error, :missing_output} = Wavelet.present([comp], roots: [root])
    assert {:error, :missing_composition} = Wavelet.present(["-o", Path.join(root, "x.pptx")])

    assert {:error, {:invalid, :w}} =
             Wavelet.present([comp, "-o", Path.join(root, "x.pptx"), "--w", "999999"], roots: [root])
  end

  test "wavelet present: missing composition is refused", %{root: root} do
    out = Path.join(root, "nope.pptx")

    assert {:error, {:composition_missing, _}} =
             Wavelet.present(["/nonexistent/deck.html", "-o", out], roots: [root])
  end

  # ── film (in-nexus workbook filming) ────────────────────────────────────────

  # Two workbook edit STATES as full HTML docs with distinct backgrounds, so the
  # rendered scenes (and hence the encoded video) genuinely differ step-to-step.
  @snap_one """
  <!doctype html><html><head><style>
    html,body{margin:0;background:#0b1020;color:#fff;font-family:sans-serif}
    h1{padding:40px;font-size:48px}
  </style></head><body><h1>Blank workbook</h1></body></html>
  """

  @snap_two """
  <!doctype html><html><head><style>
    html,body{margin:0;background:#149157;color:#fff;font-family:sans-serif}
    h1{padding:40px;font-size:48px}
  </style></head><body><h1>Added a chart</h1></body></html>
  """

  defp nb_frames(path) do
    String.to_integer(probe(path, "nb_frames"))
  end

  test "ensure_film_registered binds the film wasm as a CommandRegistry command" do
    assert {:ok, name} = Wavelet.ensure_film_registered()
    assert name == Wavelet.film_command()
    assert {:wasm, path, :argv} = Workbooks.CommandRegistry.current(name)
    assert File.regular?(path)
    assert {:ok, ^name} = Wavelet.ensure_film_registered()
  end

  test "wavelet film: an edit-state timeline (inline snapshots) -> IN-GUEST H.264 mp4",
       %{root: root} do
    # Inline snapshots, each held 0.5s, with a 0.3s crossfade cut between them.
    timeline = [
      %{"snapshot_html" => @snap_one, "label" => "Created a fresh workbook", "hold_secs" => 0.5},
      %{"snapshot_html" => @snap_two, "label" => "Added a bar chart cell", "hold_secs" => 0.5}
    ]

    tl = Path.join(root, "timeline.json")
    File.write!(tl, Jason.encode!(timeline))
    out = Path.join(root, "demo.mp4")

    # The exact bash-tenant film surface — frames rendered in-guest (no host
    # browser), encoded in-guest H.264 (no native exec, no broker grant).
    assert {:ok, delivered} =
             Wavelet.command(
               ["film", tl, "-o", out, "--w", "160", "--h", "90", "--fps", "10", "--crossfade", "0.3"],
               roots: [root]
             )

    assert delivered == Path.expand(out)
    assert File.regular?(delivered)
    # mp4 magic: bytes 4..7 == "ftyp"
    assert <<_::32, "ftyp", _::binary>> = File.read!(delivered)
    assert probe(delivered, "codec_name") == "h264"
    assert probe(delivered, "pix_fmt") == "yuv420p"

    # hold 0.5s @ 10fps = 5 frames each; crossfade 0.3s = 3 frames. 5+3+5 = 13.
    assert nb_frames(delivered) == 13
  end

  test "wavelet film: a snapshot_file ref resolves in the sandbox + wrapped {steps:[...]} form",
       %{root: root} do
    # snapshot_file points at a sibling of the timeline; the host stages the whole
    # timeline dir so the ref resolves in-sandbox.
    snap = Path.join(root, "snap2.html")
    File.write!(snap, @snap_two)

    timeline = %{
      "steps" => [
        %{"snapshot_html" => @snap_one, "label" => "step 1", "hold_secs" => 0.4},
        %{"snapshot_file" => "snap2.html", "label" => "step 2", "hold_secs" => 0.4}
      ]
    }

    tl = Path.join(root, "tl.json")
    File.write!(tl, Jason.encode!(timeline))
    out = Path.join(root, "fileref.mp4")

    assert {:ok, delivered} =
             Wavelet.command(
               ["film", tl, "-o", out, "--w", "160", "--h", "90", "--fps", "10", "--crossfade", "0"],
               roots: [root]
             )

    assert File.regular?(delivered)
    assert probe(delivered, "codec_name") == "h264"
    # hard cut (crossfade 0): 4 + 4 = 8 frames.
    assert nb_frames(delivered) == 8
  end

  test "wavelet film --audio: muxes a narration track IN-GUEST (no broker)", %{root: root} do
    timeline = [
      %{"snapshot_html" => @snap_one, "label" => "intro", "hold_secs" => 1.0},
      %{"snapshot_html" => @snap_two, "label" => "the build", "hold_secs" => 1.0}
    ]

    tl = Path.join(root, "narrated.json")
    File.write!(tl, Jason.encode!(timeline))

    mp3 = Path.join(root, "vo.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=2", mp3],
        stderr_to_stdout: true
      )

    out = Path.join(root, "narrated.mp4")

    assert {:ok, delivered} =
             Wavelet.command(
               ["film", tl, "-o", out, "--w", "160", "--h", "90", "--fps", "10",
                "--crossfade", "0.2", "--audio", mp3],
               roots: [root]
             )

    assert probe(delivered, "codec_name") == "h264"

    {a, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1:nk=1", delivered],
        stderr_to_stdout: true
      )

    assert String.trim(a) == "aac"
  end

  test "wavelet film argv validation: bad ext, missing input/output, bad dim/crossfade",
       %{root: root} do
    tl = Path.join(root, "v.json")
    File.write!(tl, "[]")

    assert {:error, :output_not_mp4} =
             Wavelet.film([tl, "-o", Path.join(root, "x.webm")], roots: [root])

    assert {:error, :missing_output} = Wavelet.film([tl], roots: [root])
    assert {:error, :missing_timeline} = Wavelet.film(["-o", Path.join(root, "x.mp4")])

    assert {:error, {:invalid, :w}} =
             Wavelet.film([tl, "-o", Path.join(root, "x.mp4"), "--w", "999999"], roots: [root])

    assert {:error, {:invalid, :crossfade}} =
             Wavelet.film([tl, "-o", Path.join(root, "x.mp4"), "--crossfade", "-1"], roots: [root])
  end

  test "wavelet film: missing timeline is refused", %{root: root} do
    out = Path.join(root, "nope.mp4")

    assert {:error, {:timeline_missing, _}} =
             Wavelet.film(["/nonexistent/timeline.json", "-o", out], roots: [root])
  end

  test "wavelet film: an empty timeline is refused by the in-guest renderer", %{root: root} do
    tl = Path.join(root, "empty.json")
    File.write!(tl, "[]")
    out = Path.join(root, "empty.mp4")

    assert {:error, {:film_failed, _, _}} =
             Wavelet.film([tl, "-o", out, "--w", "160", "--h", "90"], roots: [root])

    refute File.exists?(out)
  end
end
