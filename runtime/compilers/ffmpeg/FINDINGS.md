# ffmpeg encode lane — FINDINGS

Closing the last **bedrock gap** in the wavelet video pipeline: the mp4 ENCODE now
runs INSIDE the wasm sandbox under wasmtime — **no host ffmpeg, no native exec**.

Codec (default, Phase 2): in-guest **libx264** (GPL, cross-compiled to wasm32-wasi)
→ **H.264** + native **AAC** audio, `mp4` muxer, `png` decoder, `image2` demuxer,
`scale/format` filters — broadcast quality (CRF 18) matching the host broker. A
dependency-free `mpeg4` fallback (no external libs) remains via `vcodec: "mpeg4"`.

## Stage 1 — cross-compile minimal ffmpeg -> wasm32-wasi (wasi-sdk-25) — DONE
ffmpeg CLI (fftools/) can't build threadless (pthread_create in demux/mux). The
libav* LIBS build clean single-threaded, so the lane links a tiny transcode driver
(wb_encode.c) against them. Walls fixed: png_decoder needs zlib (built zlib 1.3.1
for wasi, --enable-zlib); dup/pipe/mkstemp/tempnam undeclared (wasi-shim.h ENOSYS
stubs); configure mis-detects host POSIX for the unknown wasm32 arch (config.h
post-process zeroes ~20 host-only HAVE_* macros). Result: wb_encode.wasm ~2.1MB,
ZERO non-wasi imports. The working configure line is reproduced in build.sh.

## Stage 2 — run in sandbox on a real wavelet PNG sequence — DONE/PROVEN
render_seq.wasm -> 30x frame_%05d.png (320x240 RGBA, no GPU); then
`wasmtime run --dir frames::/in --dir out::/out wb_encode.wasm /in/frame_%05d.png
/out/out.mp4 30` -> 58KB mp4. ffprobe (inspect only): mpeg4 320x240 yuv420p 30
frames ~0.97s. Frame 12 extracted + visually matched source frame_00012.png.

## Stage 3 — Forge lane + wiring — DONE
build.sh (fetch+sha-verify wasi-sdk/zlib/ffmpeg, cross-compile, link; idempotent,
reproduced from clean exit 0), wb_encode.c, manifest.org (CLI_BIN wb_encode, KIND
encode), .gitignore. Wiring: host/wavelet_encode.ex (Workbooks.WaveletEncode —
provisions via Compilers.build("ffmpeg"), registers wb-encode command, runs under
wasmtime). host/wavelet.ex encode/5 now has two engines via opts[:encode_engine]:
:in_guest (DEFAULT, mpeg4/mp4 + in-guest AAC audio — see Phase 1 below — no native
exec, no broker grant) and :host (FfmpegBroker, libx264/H.264). [Originally --audio
auto-fell-back to :host; Phase 1 removed that fallback.]

## Stage 4 / Phase 3 — TURNKEY IN-SANDBOX BUILD via our clang.wasm — DONE/PROVEN
The ENTIRE build now uses OUR in-sandbox clang.wasm toolchain (runtime/compilers/
clang -> llvm.core.wasm = clang + wasm-ld + a full wasi sysroot). There is NO host
wasi-sdk compiler dependency anymore — the old wasi-sdk cross-compile path is gone
from build.sh. The duckdb ddb-link.sh pattern, generalized:

  1. CONFIGURE via clang.wasm (one-time, cached). ffmpeg's configure runs host-side
     as a shell DRIVER, but the `cc` it invokes for its ~290 cross-compile PROBES is
     clang.wasm, wrapped by ccw.sh. ccw.sh: translates host probe paths under the
     scratch dir to /work guest paths, mounts the clang-root sysroot at /usr, and —
     because WASI can't spawn subprocesses (so the clang DRIVER can't call wasm-ld
     itself) — SPLITS link probes into clang `-c` then a separate wasm-ld invocation
     (crt1 + libc + emulated libs). configure is pointed at the fixed scratch via
     --tempprefix (its real dir = $tempprefix.$HOSTNAME.$UID, so ccw mounts the whole
     .build as /work). PROVEN: ffmpeg configure ran to exit 0 under clang.wasm,
     emitting config.h (License LGPL; mpeg4+AAC+png+mp4 / +GPL+libx264 for H.264).
     COST: ~14 min (clang.wasm is a ~100MB module; each probe ~6s). One-time — build.sh
     skips configure when config.h exists.
  2. HARVEST the curated .c set from `make -n` (every compile rule it would run),
     filtered to libav*/libsw* sources, sorted-unique -> 320 ffmpeg TUs. (For x264:
     clear stale .o + libx264.a first so `make -n` re-emits the full object list; map
     each -8.o/-10.o suffix to its .c + -DBIT_DEPTH/-DHIGH_BIT_DEPTH the way x264's
     Makefile does -> 53 TUs incl. the 8/10-bit multilib.)
  3. COMPILE every .c with clang.wasm (target wasm32-wasip1, --sysroot=/usr =
     clang-root). PROVEN: all 320 ffmpeg TUs compiled in-sandbox, ZERO failures; all
     53 libx264 TUs compiled in-sandbox, ZERO failures. zlib (14 TUs) likewise.
  4. LINK the whole .o set + the wb_encode.c driver with wasm-ld (crt1-command.o +
     -lz -lx264 + the wasi-emulated libs + libclang_rt.builtins.a). PROVEN.

WALL (cleared) — `-include shim.h` crashes clang.wasm (DirectoryEntry has_value()
assertion -> wasm trap). The shim is injected instead via `#include "wasi-shim.h"`
at the top of BOTH generated config headers (config.h + config_components.h) — every
ffmpeg TU pulls one of them, so the dup/pipe/mkstemp ENOSYS stubs reach the dead
file/protocol code paths without -include.

EMPIRICALLY PROVEN end-to-end (mpeg4+AAC config, built 100% by clang.wasm + wasm-ld,
NO wasi-sdk): wb_encode_cw.wasm = 2.65MB; wasm-tools confirms ALL 22 imports are
wasi (ZERO non-wasi, no native exec). Ran under wasmtime on a real render_seq.wasm
PNG sequence (30 frames 320x240, tier1_scene.html) + a 440Hz mp3:
  wasmtime run --dir frames::/in --dir out::/out wb_encode_cw.wasm \
    /in/frame_%05d.png /out/out_av.mp4 30 /in/audio.mp3
ffprobe (inspect-only): stream0 mpeg4 320x240 yuv420p 30f; stream1 aac 44100 stereo
53f. Decoded frame 12 vs source PNG: PSNR 42dB (correct pixels). Decoded AAC ->
Goertzel: 440Hz dominates every other bin by ~3e8 (tone survived mp3->AAC). Video-
only (3-arg) regression-clean. libx264.a (8+10-bit) ALSO built in-sandbox for the
H.264 default; the full x264-enabled wb_encode.wasm is produced by `./build.sh`
(its configure flips on --enable-gpl --enable-libx264).

build.sh is turnkey + idempotent: provisions clang.wasm if absent, fetches+sha-
verifies zlib/ffmpeg/x264, builds zlib+libx264 via clang.wasm, configures ffmpeg via
ccw (cached), harvests + compiles the curated set, wasm-ld-links -> wb_encode.wasm.
The artifact name/CLI/host-wiring are unchanged, so it's a drop-in for Phases 1-2.

## Phase 1 — IN-GUEST AUDIO — DONE/PROVEN
The `--audio` path no longer falls back to the host broker. Extended the lane to
mux a native AAC track ENTIRELY in-sandbox alongside the mpeg4 video.

build.sh configure additions (all ffmpeg built-ins, NO external audio libs):
  --enable-decoder=mp3,mp3float,aac,pcm_s16le,pcm_f32le
  --enable-demuxer=mp3,aac,wav,pcm_s16le
  --enable-parser=mpegaudio,aac
  --enable-encoder=aac            (ffmpeg's own AAC encoder — not libfdk/no GPL)
  --enable-bsf=aac_adtstoasc,extract_extradata
  --enable-filter=...,aresample,aformat,anull   (resample + channel/fmt convert)

wb_encode.c: optional 4th argv = audio path. Pipeline = decode (mp3/aac/wav) ->
abuffer -> aformat(44100/stereo/fltp) -> abuffersink(frame_size=AAC's 1024) ->
AAC encoder -> 2nd mp4 stream. Audio stream is wired BEFORE write_header so the
mp4 declares both streams; audio is drained AFTER the video so packets interleave.
aformat does the resample+upmix (proven: a 22050Hz MONO mp3 -> 44100/stereo AAC).

PROVEN under wasmtime (NO native exec, NO broker, only wasi imports — verified via
wasm-tools): 30 PNG frames + a 1.2s 440Hz stereo mp3 ->
`wasmtime run --dir frames::/in --dir out::/out wb_encode.wasm
/in/frame_%05d.png /out/out_av.mp4 30 /in/audio.mp3`. ffprobe (inspect only):
stream0 mpeg4 320x240 yuv420p 30f; stream1 aac 44100 stereo 1.2s 53f. Decoded the
AAC back -> Goertzel: 440Hz power dominates the next-strongest bin by ~5 orders of
magnitude — the tone survived the full mp3->AAC re-encode. Video-only mode (3-arg)
still produces a single mpeg4 stream (regression-clean). wasm grew 2.1MB -> 3.1MB.

Host wiring: WaveletEncode.encode/3 gained an `:audio` opt — stages the source
into the frames dir (so it's reachable under the single `/in` wasi preopen) and
appends the 4th argv. wavelet.ex `:in_guest` engine now passes `p.audio` through
instead of auto-falling-back to `:host` when audio is present. mix test green
(wavelet_command + ffmpeg_broker, 17/17; the --audio test now asserts in-guest
mpeg4+aac, no broker grant).

## Phase 2 — IN-GUEST H.264 (libx264) — DONE/PROVEN
The in-guest lane now encodes **H.264** via a wasm32-wasi build of **libx264**
(GPL). This is the default video codec — `wavelet render` output is H.264+AAC
matching the host broker's quality, so the broker is no longer needed for quality.

build.sh additions:
  - Step 1b: fetch (sha-verified) + cross-compile libx264 -> wasm32-wasi static lib.
    x264's configure is a hand-written shell script. Two surgical, reproducible
    patches (applied by build.sh via perl after extract):
      (a) config.sub (2012 vintage) doesn't know wasm32/wasi -> short-circuit
          `wasm32-*` targets to echo `wasm32-unknown-wasi` (top of config.sub).
      (b) configure's host_os `case` has no wasi -> add `wasi*)` => SYS=LINUX,
          libm=-lm. CRUCIALLY do NOT `define HAVE_MALLOC_H`: that path calls
          memalign() which wasi-libc lacks; without it x264 uses its portable
          malloc()+manual-align fallback (compiles+runs clean on wasm).
    configure flags: --host=wasm32-unknown-wasi --disable-cli --enable-static
      --disable-asm --disable-thread --disable-opencl --disable-{avs,swscale,lavf,
      ffms,gpac,lsmash} --disable-interlaced. AR must be the BARE binary (configure
      appends the `rc` operation itself — passing `llvm-ar rc` yields `rc rc`).
    Builds libx264.a (~2.5MB, 8-bit + 10-bit). NO asm/nasm, NO threads.
  - ffmpeg configure: --enable-gpl --enable-libx264 --enable-encoder=libx264
    --enable-parser=h264; libx264 has no pkg-config in our cross tree so the probe
    is pointed at the static lib + headers via --extra-cflags(-I$X264DIR)/
    --extra-ldflags(-L$X264DIR)/--extra-libs("-lx264 -lm"). configure links its
    libx264 test program for wasm32-wasi and reports License: GPL, CONFIG_LIBX264=1.
  - link: wb_encode.wasm now also links -lx264 -lm.

wb_encode.c: default video codec = "h264" (libx264) — CRF 18, preset medium,
profile High, GOP=2s, max_b_frames=2 (libx264 private AVOptions set before open2).
Optional 5th argv (or WB_VCODEC env) = "mpeg4" selects the dependency-free fallback.
If libx264 is somehow unavailable it auto-falls-back to mpeg4.

PROVEN under wasmtime (clean full build.sh from scratch, ~27s; NO native exec, NO
broker — wasm-tools confirms ALL 22 imports are wasi, ZERO non-wasi):
  wasmtime run --dir frames::/in --dir out::/out wb_encode.wasm \
    /in/frame_%05d.png /out/h264.mp4 30 /in/audio.mp3
  libx264 ran in-guest (logged: "profile High, level 1.3, 4:2:0, 8-bit ... crf=18.0").
  ffprobe (inspect only): stream0 h264 High yuv420p 320x240 30f; stream1 aac LC
  44100 stereo. Decoded H.264 frame 12 vs the source PNG: PSNR_avg 49.1 dB / PSNR_y
  47.6 dB (CRF-18 visually-lossless — correct pixels, not garbage). Decoded the AAC
  back -> Goertzel: 440Hz power dominates every other bin by ~9 orders of magnitude
  (tone survived mp3->AAC through the H.264 pipeline). mpeg4 fallback (vcodec=mpeg4)
  and video-only H.264 (3-arg) both verified. wasm grew 3.1MB -> 4.1MB.

Host wiring: WaveletEncode.encode/3 gained a `:vcodec` opt (default "h264", appended
as the driver's 5th argv; "" pads position 4 when no audio). wavelet.ex `:in_guest`
engine passes vcodec through (default h264). ensure_registered now ALWAYS goes
through Compilers.build (idempotent — build.sh early-exits if the wasm exists) so a
rebuilt wasm hot-swaps the persisted registration by content hash. mix test 18/18
green (wavelet_command + ffmpeg_broker): default render = h264, vcodec:mpeg4 fallback,
--audio = h264+aac in-guest, encode_engine::host still default-deny.

## Phase 4 — INTEGRATE + FINISH — DONE/PROVEN
`:in_guest` (H.264+AAC, no broker grant) is the full-quality DEFAULT. The host
`FfmpegBroker` survives ONLY as an explicit `encode_engine: :host` legacy/opt-in —
nothing the default path needs. wavelet.ex / wavelet_encode.ex were already wired
this way from Phases 1-3; Phase 4 closed the one remaining real-encode wall and ran
the live end-to-end.

WALL (cleared) — FUEL EXHAUSTION on a real encode. The in-guest run lane bounded the
wasm with BOTH `-W timeout` AND `-W fuel=5e9` (and WaveletEncode passed `fuel: 5e11`).
A legitimate H.264 encode of a 12s 720p clip (360 frames + AAC) burns FAR more than
5e11 fuel before finishing, so wasmtime trapped mid-stream (`wasm trap: all fuel
consumed`, exit 134) — even though the identical run with no fuel cap completed (8.9MB
mp4, "DONE encoded 360 frames + audio"). Fuel is the wrong DoS bound for a
legitimately compute-heavy lane. Fix: `run_wasmtime` now accepts `fuel: :unlimited`
(or `0`) → it OMITS `-W fuel` entirely and relies on the wall-clock `-W timeout` to
kill a runaway (the threads path already drops fuel for the same reason).
`WaveletEncode.encode/3` passes `fuel: :unlimited` (bounded by `timeout_ms`). The
generic default fuel is untouched, so every other command keeps its CPU-DoS guard.

LIVE END-TO-END (PROVEN, NO broker grant): an agent-authored composition (`comp.html`
— a fade-in WORKBOOKS title card + sliding green box + growing progress bar) WITH
ElevenLabs narration (`narration.mp3`, ~12s) was driven through the REAL
`Workbooks.Wavelet.command(["render", comp, "-o", out, "--w","1280","--h","720",
"--fps","30","--duration","12","--audio", mp3], roots: [root])` — DEFAULT engine,
`:allow` NOT passed:
  - render_seq.wasm rasterized 360 frames IN-SANDBOX (no GPU);
  - wb_encode.wasm encoded H.264+AAC IN-GUEST under wasmtime (NO native exec — all 22
    imports are wasi_snapshot_preview1, verified via wasm-tools);
  - result: `wavelet-final.mp4` 8,987,053 bytes. ffprobe (inspect only): video h264
    High yuv420p 1280x720 360 frames; audio aac 44100 stereo; duration 11.97s.
  - VISION-VERIFIED via `tools/record/lib/verify-only.mjs` (OPENROUTER_API_KEY in env,
    google/gemini-3.5-flash): verdict **pass**, confidence 1.0, skipped=false — the
    model confirmed the title card, body text, the "H.264 + AAC · in-guest · no native
    exec" pill, the sliding box and the growing progress bar.
  - UPLOADED to R2: `wrangler r2 object put workbooks-media/demos/wavelet-final.mp4
    --content-type=video/mp4 --remote` → "Upload complete."

The whole build was produced by OUR in-sandbox clang.wasm toolchain (Phase 3): a clean
`./build.sh` compiled all 320 ffmpeg TUs + 53 libx264 + zlib in-sandbox and wasm-ld-
linked wb_encode.wasm (3.96MB) under wasmtime — NO host wasi-sdk compiler.

mix compile clean; `mix test test/wavelet_command_test.exs test/ffmpeg_broker_test.exs`
= 18/18 green (default render = in-guest h264 no grant; default + --audio = in-guest
h264+aac no grant; vcodec:mpeg4 in-guest fallback; encode_engine::host = legacy broker
still default-deny).

## Nothing remains
The wavelet mp4-encode bedrock gap is fully closed: H.264 + AAC (incl. narration audio)
encode runs IN-GUEST under wasmtime as the zero-trust DEFAULT, at broker-matching
quality, with NO native exec and NO broker grant — proven by a live agent-authored,
vision-verified, R2-published video. The host FfmpegBroker remains only as an explicit
opt-in escape hatch; it is no longer a quality requirement for anything.
