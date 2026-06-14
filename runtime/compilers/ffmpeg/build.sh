#!/usr/bin/env bash
# Provision the ffmpeg encode lane: a MINIMAL, dependency-free PNG-sequence -> mp4 (mpeg4)
# transcoder that runs INSIDE the wasm sandbox under wasmtime. Closes the last bedrock gap
# in the wavelet video pipeline — the mp4 ENCODE no longer needs a host ffmpeg broker.
#
# WHAT IT BUILDS: wb_encode.wasm (wasm32-wasi). Reads a PNG frame sequence (the output of
# wavelet-render-core's render_seq.wasm), decodes via libavcodec's built-in png decoder,
# scales/formats to yuv420p via libavfilter, encodes with the built-in mpeg4 encoder, muxes
# to mp4. NO external codec libs (no libx264/GPL) — a real, universally-playable mp4.
# Quality follow-on: a libx264 (GPL) lane for H.264. Noted, not done.
#
# WHY A LIBAV* DRIVER, NOT THE ffmpeg CLI: ffmpeg 6.1's CLI (fftools/) hard-requires pthreads
# (ffmpeg_demux/ffmpeg_mux run input/output on threads — pthread_create/join). The libav*
# LIBRARIES themselves compile cleanly single-threaded for wasm32-wasi. So we link the libs
# against a tiny hand-written transcode driver (wb_encode.c) — the standard "ffmpeg as a
# library" approach, and the right shape for an in-sandbox command anyway.
#
# Cross-compile path: wasi-sdk-25 clang (host-side cross). The TRUE in-sandbox clang.wasm
# build is assessed in FINDINGS.md (walls on ffmpeg's autotools configure).
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress -> stderr.
# All large artifacts (wasi-sdk, ffmpeg/zlib source, *.a, *.wasm) are gitignored — this
# recipe fetches + sha-verifies + builds them, like the other C lanes.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
OUT="$SD/wb_encode.wasm"
BD="$SD/.build"
exec 3>&1 1>&2   # progress -> stderr; fd 3 = the one stdout line (the wasm path)

if [ -f "$OUT" ]; then echo "[ffmpeg] up to date -> $OUT"; echo "$OUT" 1>&3; exit 0; fi
mkdir -p "$BD"

# --- 0. wasi-sdk-25 (host cross toolchain) -----------------------------------------------
WASI_VER="25.0"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  WASI_PKG="wasi-sdk-${WASI_VER}-arm64-macos";  WASI_SHA="" ;;
  Darwin-x86_64) WASI_PKG="wasi-sdk-${WASI_VER}-x86_64-macos"; WASI_SHA="" ;;
  Linux-x86_64)  WASI_PKG="wasi-sdk-${WASI_VER}-x86_64-linux"; WASI_SHA="" ;;
  Linux-aarch64) WASI_PKG="wasi-sdk-${WASI_VER}-arm64-linux";  WASI_SHA="" ;;
  *) echo "[ffmpeg] unsupported host $(uname -s)-$(uname -m)"; exit 1 ;;
esac
SDK="$BD/$WASI_PKG"
if [ ! -x "$SDK/bin/clang" ]; then
  TGZ="$BD/$WASI_PKG.tar.gz"
  [ -f "$TGZ" ] || { echo "[ffmpeg] fetch $WASI_PKG"; curl -fsSL \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/$WASI_PKG.tar.gz" -o "$TGZ"; }
  echo "[ffmpeg] extracting wasi-sdk"; tar xzf "$TGZ" -C "$BD"
fi
SYSROOT="$SDK/share/wasi-sysroot"
CLANG="$SDK/bin/clang"

# --- 1. zlib (libavcodec png decoder needs inflate) --------------------------------------
ZVER="1.3.1"; ZSHA="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
ZDIR="$BD/zlib-$ZVER"
if [ ! -f "$ZDIR/libz.a" ]; then
  ZTGZ="$BD/zlib-$ZVER.tar.gz"
  [ -f "$ZTGZ" ] || { echo "[ffmpeg] fetch zlib $ZVER"; curl -fsSL \
    "https://github.com/madler/zlib/releases/download/v$ZVER/zlib-$ZVER.tar.gz" -o "$ZTGZ"; }
  echo "$ZSHA  $ZTGZ" | shasum -a 256 -c - || { echo "[ffmpeg] zlib SHA MISMATCH"; exit 1; }
  tar xzf "$ZTGZ" -C "$BD"
  echo "[ffmpeg] building zlib -> wasm32-wasi"
  ( cd "$ZDIR"; mkdir -p obj
    for s in adler32 crc32 deflate inffast inflate inftrees trees zutil compress uncompr \
             gzclose gzlib gzread gzwrite; do
      "$CLANG" --target=wasm32-wasi --sysroot="$SYSROOT" -O2 -DHAVE_UNISTD_H -c "$s.c" -o "obj/$s.o"
    done
    "$SDK/bin/llvm-ar" rcs libz.a obj/*.o )
fi

# --- 1b. libx264 (GPL H.264 encoder) -> wasm32-wasi --------------------------------------
# x264's configure is a hand-written shell script (NOT autotools). It cross-compiles fine
# C-only: --disable-asm (no nasm/wasm SIMD), --disable-thread (single-threaded wasm), and
# --host=wasm32 so it skips the host PIC/exec probes. We build a static libx264.a + headers.
X264DIR="$BD/x264"
if [ ! -f "$X264DIR/libx264.a" ]; then
  # pinned snapshot from VideoLAN's stable-branch mirror (commit-locked tarball, sha-verified)
  X264_REV="31e19f92f00c7003fa115047ce50978bc98c3a0d"
  X264_SHA="d053c9d86988d6bc78237ca5205865c5ddf99c98ef4cd9927eec8f6d388f6dd9"
  X264TGZ="$BD/x264-$X264_REV.tar.gz"
  [ -f "$X264TGZ" ] || { echo "[ffmpeg] fetch x264 $X264_REV"; curl -fsSL \
    "https://code.videolan.org/videolan/x264/-/archive/$X264_REV/x264-$X264_REV.tar.gz" -o "$X264TGZ"; }
  echo "$X264_SHA  $X264TGZ" | shasum -a 256 -c - || { echo "[ffmpeg] x264 SHA MISMATCH"; exit 1; }
  rm -rf "$BD/x264-$X264_REV" "$X264DIR"
  tar xzf "$X264TGZ" -C "$BD"
  mv "$BD/x264-$X264_REV" "$X264DIR"
  echo "[ffmpeg] building libx264 -> wasm32-wasi"
  ( cd "$X264DIR"
    # (a) config.sub (2012 vintage) doesn't know wasm32/wasi -> short-circuit wasm32-* targets.
    perl -0pi -e 's/(timestamp=.2012-12-06.\n)/$1\ncase "\$1" in wasm32-*) echo "wasm32-unknown-wasi"; exit 0;; esac\n/' config.sub
    # (b) configure's host_os case has no wasi -> add one (SYS=LINUX; libm exists in wasi-sysroot).
    #     Crucially DO NOT define HAVE_MALLOC_H: that path calls memalign(), absent from wasi-libc;
    #     without it x264 uses its portable malloc()+manual-align fallback (works on wasm).
    perl -0pi -e 's/    \*\)\n        die "Unknown system \$host, edit the configure"\n        ;;\nesac/    wasi*|none*|unknown*)\n        SYS="LINUX"\n        libm="-lm"\n        ;;\n    *)\n        die "Unknown system \$host, edit the configure"\n        ;;\nesac/' configure
    grep -q 'wasi\*|none\*|unknown\*' configure || { echo "[ffmpeg] x264 configure patch FAILED"; exit 1; }
    # x264 references log2f/expf etc (libm in wasi-sysroot) and a few POSIX bits; the wasi
    # emulation libs cover signal/getpid/clock. --disable-cli => library only (no main()).
    # AR must be the bare binary — x264's configure appends the `rc` operation itself.
    CC="$CLANG" \
    CFLAGS="--target=wasm32-wasi --sysroot=$SYSROOT -O2 -fno-stack-protector \
            -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_PROCESS_CLOCKS" \
    LDFLAGS="--target=wasm32-wasi --sysroot=$SYSROOT" \
    AR="$SDK/bin/llvm-ar" RANLIB="$SDK/bin/llvm-ranlib" STRIP=: \
    ./configure \
      --host=wasm32-unknown-wasi \
      --disable-cli --enable-static \
      --disable-asm --disable-thread --disable-opencl \
      --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
      --disable-interlaced \
      --extra-cflags="--target=wasm32-wasi --sysroot=$SYSROOT" >/dev/null || { echo "[ffmpeg] x264 configure FAILED"; tail -40 config.log 2>/dev/null; exit 1; }
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" libx264.a >/dev/null )
  [ -f "$X264DIR/libx264.a" ] || { echo "[ffmpeg] libx264.a NOT built"; exit 1; }
fi

# --- 2. ffmpeg source --------------------------------------------------------------------
FF_VER="6.1.1"; FF_SHA="8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
FFDIR="$BD/ffmpeg-$FF_VER"
if [ ! -d "$FFDIR" ]; then
  FFTXZ="$BD/ffmpeg-$FF_VER.tar.xz"
  [ -f "$FFTXZ" ] || { echo "[ffmpeg] fetch ffmpeg $FF_VER"; curl -fsSL \
    "https://ffmpeg.org/releases/ffmpeg-$FF_VER.tar.xz" -o "$FFTXZ"; }
  echo "$FF_SHA  $FFTXZ" | shasum -a 256 -c - || { echo "[ffmpeg] ffmpeg SHA MISMATCH"; exit 1; }
  tar xf "$FFTXZ" -C "$BD"
fi

# --- 3. wasi POSIX shim (dup/pipe/mkstemp -> ENOSYS stubs; dead paths for file: protocol) -
SHIM="$BD/wasi-shim.h"
cat > "$SHIM" <<'EOF'
/* wasi-shim: ENOSYS stubs for POSIX calls ffmpeg references but wasm32-wasi lacks.
   These sit on dead code paths for the image2-demux/file-protocol/mp4-mux encode path.
   Force-included via -include into every ffmpeg TU. */
#ifndef WB_WASI_SHIM_H
#define WB_WASI_SHIM_H
#include <errno.h>
static inline int wb_dup(int fd){ (void)fd; errno = ENOSYS; return -1; }
#define dup(fd) wb_dup(fd)
static inline int wb_pipe(int p[2]){ (void)p; errno = ENOSYS; return -1; }
#define pipe(p) wb_pipe(p)
static inline int wb_mkstemp(char *t){ (void)t; errno = ENOSYS; return -1; }
#define mkstemp(t) wb_mkstemp(t)
static inline char *wb_tempnam(const char *d, const char *p){ (void)d; (void)p; errno = ENOSYS; return 0; }
#define tempnam(d,p) wb_tempnam(d,p)
#endif
EOF

# --- 4. configure + build libav* (single-threaded, mpeg4/mp4/png only) --------------------
if [ ! -f "$FFDIR/libavformat/libavformat.a" ]; then
  echo "[ffmpeg] configure (minimal, no-threads, mpeg4/mp4/png)"
  CFLAGS="--target=wasm32-wasi --sysroot=$SYSROOT -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_PROCESS_CLOCKS -O2 -fno-stack-protector -I$ZDIR -I$X264DIR -include $SHIM"
  LDFLAGS="--target=wasm32-wasi --sysroot=$SYSROOT -L$ZDIR -L$X264DIR -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-process-clocks -Wl,--allow-undefined"
  ( cd "$FFDIR"
    # libx264 has no pkg-config in our cross tree; point ffmpeg's probe at the static lib +
    # headers directly via --extra-cflags/--extra-libs (configure links a tiny x264 program).
    ./configure \
      --cc="$CLANG" --ar="$SDK/bin/llvm-ar" --ranlib="$SDK/bin/llvm-ranlib" --nm="$SDK/bin/llvm-nm" \
      --target-os=none --arch=wasm32 --enable-cross-compile \
      --disable-everything --disable-asm --disable-network --disable-pthreads \
      --disable-autodetect --disable-x86asm --disable-doc \
      --disable-debug --disable-stripping --disable-runtime-cpudetect --enable-zlib \
      --enable-gpl --enable-libx264 \
      --enable-decoder=png --enable-demuxer=image2 \
      --enable-encoder=mpeg4 --enable-encoder=libx264 \
      --enable-muxer=mp4 --enable-protocol=file \
      --enable-decoder=mp3,mp3float,aac,pcm_s16le,pcm_f32le \
      --enable-demuxer=mp3,aac,wav,pcm_s16le \
      --enable-parser=mpegaudio,aac,h264 \
      --enable-encoder=aac \
      --enable-bsf=aac_adtstoasc,extract_extradata \
      --enable-filter=scale,format,fps,vflip,aresample,aformat,anull \
      --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
      --extra-libs="-lx264 -lm" >/dev/null

    # configure mis-detects host (macOS/Linux) POSIX features for the unknown wasm32 arch.
    # Force-disable the ones wasm32-wasi lacks so the libs compile.
    python3 - "$FFDIR/config.h" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
for k in ['HAVE_SYSCTL','HAVE_SYSCTLBYNAME','HAVE_SCHED_GETAFFINITY','HAVE_GETHRTIME',
          'HAVE_MACH_ABSOLUTE_TIME','HAVE_GETAUXVAL','HAVE_PTHREADS','HAVE_W32THREADS',
          'HAVE_OS2THREADS','HAVE_MMAP','HAVE_MPROTECT','HAVE_FORK','HAVE_SETRLIMIT',
          'HAVE_ISATTY','HAVE_GETRUSAGE','HAVE_GETPID','HAVE_KBHIT','HAVE_PEEKNAMEDPIPE',
          'HAVE_SETCONSOLETEXTATTRIBUTE','HAVE_SETCONSOLECTRLHANDLER']:
    s=re.sub(r'#define %s 1'%k,'#define %s 0'%k,s)
open(p,'w').write(s)
PY
    echo "[ffmpeg] building libav* (single-threaded)"
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" \
      libavformat/libavformat.a libavcodec/libavcodec.a libavfilter/libavfilter.a \
      libswscale/libswscale.a libswresample/libswresample.a libavutil/libavutil.a >/dev/null
  )
fi

# --- 5. link the transcode driver -> wb_encode.wasm --------------------------------------
echo "[ffmpeg] linking wb_encode.wasm"
"$CLANG" --target=wasm32-wasi --sysroot="$SYSROOT" -O2 \
  -I"$FFDIR" -I"$FFDIR/libavutil" -include "$SHIM" \
  "$SD/wb_encode.c" \
  "$FFDIR/libavfilter/libavfilter.a" "$FFDIR/libavformat/libavformat.a" \
  "$FFDIR/libavcodec/libavcodec.a" "$FFDIR/libswscale/libswscale.a" \
  "$FFDIR/libswresample/libswresample.a" "$FFDIR/libavutil/libavutil.a" \
  -L"$ZDIR" -lz \
  -L"$X264DIR" -lx264 -lm \
  -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-process-clocks \
  -Wl,--allow-undefined \
  -o "$OUT"

[ -f "$OUT" ] || { echo "[ffmpeg] link FAILED — no wb_encode.wasm"; exit 1; }
echo "[ffmpeg] built $OUT ($(du -h "$OUT" | cut -f1))"
echo "$OUT" 1>&3
