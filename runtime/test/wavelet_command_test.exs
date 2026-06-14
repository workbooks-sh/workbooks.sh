defmodule Workbooks.WaveletCommandTest do
  @moduledoc """
  End-to-end proof of the Phase-3 `wavelet render` toolkit command: a bash-only
  tenant authors an HTML composition and runs ONE command that renders the frame
  sequence IN-SANDBOX (the render-core wasm via CommandRegistry) then muxes it to
  an h264 mp4 via the host ffmpeg encode broker. Empirical — actually runs the
  wasm under wasmtime and shells ffmpeg/ffprobe, never faked.
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

  test "wavelet render: in-sandbox frames -> brokered h264 mp4", %{root: root} do
    comp = Path.join(root, "clip.html")
    File.write!(comp, @composition)
    out = Path.join(root, "clip.mp4")

    # The exact bash-tenant command surface: a token list after `wavelet`.
    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12", "--duration", "1"],
               allow: true,
               roots: [root]
             )

    assert delivered == Path.expand(out)
    assert File.regular?(delivered)
    # mp4 magic: bytes 4..7 == "ftyp"
    assert <<_::32, "ftyp", _::binary>> = File.read!(delivered)
    # the encode broker produced real h264/yuv420p
    assert probe(delivered, "codec_name") == "h264"
    assert probe(delivered, "pix_fmt") == "yuv420p"
  end

  test "wavelet render --audio: muxes an mp3 as an aac track", %{root: root} do
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

    assert {:ok, delivered} =
             Wavelet.command(
               ["render", comp, "-o", out, "--w", "160", "--h", "90", "--fps", "12",
                "--duration", "2", "--audio", mp3],
               allow: true,
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

  test "encode default-deny: render runs but mux refuses without the encode grant", %{root: root} do
    comp = Path.join(root, "deny.html")
    File.write!(comp, @composition)
    out = Path.join(root, "deny.mp4")

    # No allow: true -> the broker's default-deny rejects the mux. The frames were
    # rendered in-sandbox first; the cap gates only the bedrock-escape encode.
    assert {:error, :denied} =
             Wavelet.command(["render", comp, "-o", out, "--fps", "12", "--duration", "1"],
               roots: [root]
             )

    refute File.exists?(out)
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
end
