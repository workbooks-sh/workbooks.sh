defmodule Workbooks.FfmpegBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.FfmpegBroker

  @moduletag :ffmpeg

  # A 2x2 solid-color PNG, generated with ffmpeg's lavfi (so the test has no image-lib dep). Returns the
  # bytes of a single PNG frame painted `color` (an ffmpeg color name).
  defp png_frame(color) do
    tmp = Path.join(System.tmp_dir!(), "wb_frame_src_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "color=c=#{color}:s=2x2", "-frames:v", "1", tmp],
        stderr_to_stdout: true
      )

    bin = File.read!(tmp)
    File.rm(tmp)
    bin
  end

  defp make_frames(dir, n) do
    File.mkdir_p!(dir)
    colors = ~w(red green blue white)
    for i <- 0..(n - 1) do
      name = "frame_" <> String.pad_leading(Integer.to_string(i), 5, "0") <> ".png"
      File.write!(Path.join(dir, name), png_frame(Enum.at(colors, rem(i, length(colors)))))
    end
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "wb_encode_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  setup do
    if System.find_executable("ffmpeg") == nil, do: raise("ffmpeg not on PATH — required for this test")
    :ok
  end

  test "DEFAULT-DENY — no grant means nothing encodes" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 3)
    out = Path.join(root, "out.mp4")

    assert {:error, :denied} = FfmpegBroker.encode(frames, out, roots: [root])
    refute File.exists?(out)
  end

  test "PATH GATING — inputs/outputs outside the roots are refused pre-exec" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 3)

    # output escaping the root
    assert {:error, :path_not_gated} =
             FfmpegBroker.encode(frames, "/tmp/escape_#{System.unique_integer([:positive])}.mp4",
               allow: true,
               roots: [root]
             )

    # frames dir traversing out of the root
    assert {:error, :path_not_gated} =
             FfmpegBroker.encode(Path.join(frames, "../../etc"), Path.join(root, "o.mp4"),
               allow: true,
               roots: [root]
             )
  end

  test "ARG-SMUGGLING — a non-integer fps cannot become an ffmpeg token" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 3)

    assert {:error, {:invalid, :fps}} =
             FfmpegBroker.encode(frames, Path.join(root, "o.mp4"),
               allow: true,
               roots: [root],
               fps: "30 -vf=evil"
             )
  end

  test "REVOCATION — a revoked principal cannot encode" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 3)
    p = "encode-rev-#{System.unique_integer([:positive])}"
    :ok = Workbooks.Revocation.revoke(p)

    assert {:error, :revoked} =
             FfmpegBroker.encode(frames, Path.join(root, "o.mp4"),
               allow: true,
               roots: [root],
               principal: p
             )

    :ok = Workbooks.Revocation.unrevoke(p)
  end

  test "non-contiguous frames are refused" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    File.mkdir_p!(frames)
    File.write!(Path.join(frames, "frame_00000.png"), png_frame("red"))
    File.write!(Path.join(frames, "frame_00002.png"), png_frame("blue"))

    assert {:error, :non_contiguous_frames} =
             FfmpegBroker.encode(frames, Path.join(root, "o.mp4"), allow: true, roots: [root])
  end

  test "ENCODE — frames -> a real h264/yuv420p mp4 (verified with ffprobe)" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 8)
    out = Path.join(root, "clip.mp4")

    assert {:ok, ^out} = FfmpegBroker.encode(frames, out, allow: true, roots: [root], fps: 8)
    assert File.exists?(out)
    assert File.stat!(out).size > 0

    # Verify the container is really h264 + yuv420p via ffprobe.
    {info, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=codec_name,pix_fmt", "-of", "default=nw=1", out],
        stderr_to_stdout: true
      )

    assert info =~ "codec_name=h264"
    assert info =~ "pix_fmt=yuv420p"
  end

  test "ENCODE with audio — muxes an AAC track" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 8)
    out = Path.join(root, "clip_audio.mp4")

    # generate a short mp3 inside the root (so it path-gates)
    audio = Path.join(root, "tone.mp3")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=1", audio],
        stderr_to_stdout: true
      )

    assert {:ok, ^out} =
             FfmpegBroker.encode(frames, out, allow: true, roots: [root], fps: 8, audio: audio)

    {info, 0} =
      System.cmd(
        "ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name",
         "-of", "default=nw=1", out],
        stderr_to_stdout: true
      )

    assert info =~ "codec_name=aac"
  end

  test "encode_to_bytes returns the mp4 bytes and cleans up the temp file" do
    root = tmp_root()
    frames = Path.join(root, "frames")
    make_frames(frames, 4)

    before = root |> File.ls!() |> Enum.count(&String.starts_with?(&1, "wb_encode_"))
    assert {:ok, bin} = FfmpegBroker.encode_to_bytes(frames, allow: true, roots: [root], fps: 4)
    # mp4 magic: bytes 4..7 are "ftyp"
    assert binary_part(bin, 4, 4) == "ftyp"
    after_count = root |> File.ls!() |> Enum.count(&String.starts_with?(&1, "wb_encode_"))
    assert after_count == before
  end

  test "wire request parses round-trip (the Dock import contract)" do
    frames = "/r/frames"
    out = "/r/out.mp4"
    audio = "/r/a.mp3"

    req =
      <<byte_size(frames)::little-32>> <>
        frames <>
        <<byte_size(out)::little-32>> <>
        out <>
        <<byte_size(audio)::little-32>> <> audio <> <<24::little-32, 18::little-32>>

    assert {:ok, ^frames, ^out, ^audio, 24, 18} = FfmpegBroker.parse_request(req)

    # empty audio -> nil
    req2 =
      <<byte_size(frames)::little-32>> <>
        frames <> <<byte_size(out)::little-32>> <> out <> <<0::little-32, 30::little-32, 18::little-32>>

    assert {:ok, ^frames, ^out, nil, 30, 18} = FfmpegBroker.parse_request(req2)
    assert :error = FfmpegBroker.parse_request(<<1, 2, 3>>)
  end
end
