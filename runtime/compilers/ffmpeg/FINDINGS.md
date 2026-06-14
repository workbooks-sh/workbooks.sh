# ffmpeg encode lane — FINDINGS

Closing the last **bedrock gap** in the wavelet video pipeline: the mp4 ENCODE now
runs INSIDE the wasm sandbox under wasmtime — **no host ffmpeg, no native exec**.

Codec (dependency-free): ffmpeg's built-in `mpeg4` encoder + `mp4` muxer + `png`
decoder + `image2` demuxer + `scale/format` filters. A real, universally-playable
mp4 with **no external codec libs** (no libx264/GPL). H.264 is the noted follow-on.

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
:in_guest (DEFAULT, mpeg4/mp4, no native exec, no broker grant) and :host
(FfmpegBroker, libx264/H.264 + audio). --audio auto-falls-back to :host.

## Stage 4 — true in-sandbox build via our clang.wasm — PARTIAL
COMPILATION PROVEN: clang.wasm compiled base64.c/mem.c/avstring.c/log.c and
mpeg4videoenc.c (the actual mpeg4 encoder) in-sandbox, given a pre-generated
config.h. WALL #1 (real blocker): ffmpeg's configure is autotools (168 native
compile-probes); our lane compiles curated source lists, not autotools -> configure
must run host-side ONCE to emit config.h + object list (the mutool/qpdf pattern),
then feed the curated .c set through clang.wasm + wasm-ld (duckdb ddb-link.sh
pattern). WALL #2 (found+worked-around): `-include shim.h` crashes clang.wasm
(DirectoryEntry.h has_value() assertion -> wasm trap). Workaround proven: inject
the shim via `#include "wasi-shim.h"` at the top of config.h instead. Verdict:
in-guest COMPILE proven incl. the mpeg4 encoder; a turnkey in-sandbox BUILD still
needs (a) host-side configure, (b) the curated ~260-file compile loop, (c) wasm-ld
link wired into build.sh. Mechanical, not a wall.

## Left to make in-guest encode the default for `wavelet render`
DONE: :in_guest is the default; lane self-provisions on first use. Follow-ons:
in-guest AUDIO (built-in AAC; today audio falls back to :host); H.264 via a
libx264/GPL lane; wire the Stage-4 curated compile loop into build.sh behind a flag.
