#!/usr/bin/env bash
# Provision the ffmpeg encode lane — a PNG-sequence -> mp4 transcoder that runs INSIDE the
# wasm sandbox under wasmtime. Closes the last bedrock gap in the wavelet video pipeline:
# the mp4 ENCODE no longer needs a host ffmpeg broker.
#
# PHASE 3 — TURNKEY IN-SANDBOX BUILD. The ENTIRE build now uses OUR in-sandbox clang.wasm
# toolchain (runtime/compilers/clang -> llvm.core.wasm = clang + wasm-ld + a full wasi
# sysroot). There is NO host wasi-sdk compiler dependency. The duckdb pattern:
#   1. ffmpeg `configure` runs ONCE (host-side driver, but the cc it calls IS clang.wasm via
#      ccw.sh) to emit config.h + the Makefile object list. CACHED — re-run only if absent.
#   2. zlib + libx264 + the curated ffmpeg .c set compile with clang.wasm.
#   3. wasm-ld links the whole .o set + the wb_encode.c driver -> wb_encode.wasm.
# The `-include shim.h` clang.wasm crash (FINDINGS WALL #2) is avoided by injecting the shim
# via `#include "wasi-shim.h"` at the top of config.h / config_components.h instead.
#
# WHAT IT BUILDS: wb_encode.wasm (wasm32-wasi). PNG frames (wavelet render_seq.wasm output)
# -> png decoder | image2 demuxer | scale/format(yuv420p) | H.264 (in-guest libx264, GPL) |
# mp4 muxer; optional audio: mp3/aac/wav decode | aresample/aformat | native AAC encoder ->
# 2nd mp4 stream. A dependency-free mpeg4 fallback is selectable (vcodec=mpeg4 / WB_VCODEC).
#
# WHY A LIBAV* DRIVER, NOT THE ffmpeg CLI: ffmpeg's CLI (fftools/) hard-requires pthreads;
# the libav* LIBRARIES compile cleanly single-threaded for wasm. So we link the libs against
# a hand-written transcode driver (wb_encode.c) — "ffmpeg as a library".
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress -> stderr.
# All large artifacts (clang sysroot, ffmpeg/x264/zlib source, *.a, *.o, *.wasm) are
# gitignored; this recipe fetches + sha-verifies + builds them.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
OUT="$SD/wb_encode.wasm"
BD="$SD/.build"
RT="$(cd "$SD/../.." && pwd)"               # runtime/
CLANG_LANE="$RT/compilers/clang"
CORE="$CLANG_LANE/clang-root/llvm.core.wasm"
SYSROOT="$CLANG_LANE/clang-root/sysroot"
exec 3>&1 1>&2   # progress -> stderr; fd 3 = the one stdout line (the wasm path)

if [ -f "$OUT" ]; then echo "[ffmpeg] up to date -> $OUT"; echo "$OUT" 1>&3; exit 0; fi
mkdir -p "$BD"

# --- 0. clang.wasm toolchain (our in-sandbox compiler) -----------------------------------
if [ ! -f "$CORE" ] || [ ! -d "$SYSROOT/lib" ]; then
  echo "[ffmpeg] provisioning clang.wasm lane"
  "$CLANG_LANE/build.sh" >/dev/null
fi
[ -f "$CORE" ] || { echo "[ffmpeg] clang.wasm missing at $CORE"; exit 1; }

# clang.wasm runner helpers --------------------------------------------------------------
# cwc <workdir-host::/work-mount> <args...>  : run `clang` with sysroot mounted /usr.
# We mount a single host dir as /work; callers pass /work-relative paths.
RTLIB_G=/usr/lib/wasm32-unknown-wasip1
LIBC_G=/usr/lib/wasm32-wasip1
cwc() {  # $1=hostdir(mounts /work); rest=clang argv
  local wd="$1"; shift
  local t; t="$(mktemp -d)"
  wasmtime run -C cache=y -W exceptions=y -W memory64=y \
    --dir "$SYSROOT::/usr" --dir "$wd::/work" --dir "$t::/tmp" --env TMPDIR=/tmp \
    "$CORE" clang --target=wasm32-wasip1 --sysroot=/usr "$@"
  local rc=$?; rm -rf "$t"; return $rc
}
cwar() {  # $1=hostdir(mounts /work); rest=llvm-ar argv
  local wd="$1"; shift
  wasmtime run -C cache=y --dir "$wd::/work" "$CORE" llvm-ar "$@"
}

# --- 1. fetch + verify sources -----------------------------------------------------------
ZVER="1.3.1"; ZSHA="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
ZDIR="$BD/zlib-$ZVER"
FF_VER="6.1.1"; FF_SHA="8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
FFDIR="$BD/ffmpeg-$FF_VER"
X264_REV="31e19f92f00c7003fa115047ce50978bc98c3a0d"
X264_SHA="d053c9d86988d6bc78237ca5205865c5ddf99c98ef4cd9927eec8f6d388f6dd9"
X264DIR="$BD/x264"

if [ ! -f "$ZDIR/zlib.h" ]; then
  ZTGZ="$BD/zlib-$ZVER.tar.gz"
  [ -f "$ZTGZ" ] || { echo "[ffmpeg] fetch zlib $ZVER"; curl -fsSL \
    "https://github.com/madler/zlib/releases/download/v$ZVER/zlib-$ZVER.tar.gz" -o "$ZTGZ"; }
  echo "$ZSHA  $ZTGZ" | shasum -a 256 -c - || { echo "[ffmpeg] zlib SHA MISMATCH"; exit 1; }
  tar xzf "$ZTGZ" -C "$BD"
fi
if [ ! -d "$FFDIR" ]; then
  FFTXZ="$BD/ffmpeg-$FF_VER.tar.xz"
  [ -f "$FFTXZ" ] || { echo "[ffmpeg] fetch ffmpeg $FF_VER"; curl -fsSL \
    "https://ffmpeg.org/releases/ffmpeg-$FF_VER.tar.xz" -o "$FFTXZ"; }
  echo "$FF_SHA  $FFTXZ" | shasum -a 256 -c - || { echo "[ffmpeg] ffmpeg SHA MISMATCH"; exit 1; }
  tar xf "$FFTXZ" -C "$BD"
fi
if [ ! -d "$X264DIR" ]; then
  X264TGZ="$BD/x264-$X264_REV.tar.gz"
  [ -f "$X264TGZ" ] || { echo "[ffmpeg] fetch x264 $X264_REV"; curl -fsSL \
    "https://code.videolan.org/videolan/x264/-/archive/$X264_REV/x264-$X264_REV.tar.gz" -o "$X264TGZ"; }
  echo "$X264_SHA  $X264TGZ" | shasum -a 256 -c - || { echo "[ffmpeg] x264 SHA MISMATCH"; exit 1; }
  rm -rf "$BD/x264-$X264_REV"; tar xzf "$X264TGZ" -C "$BD"; mv "$BD/x264-$X264_REV" "$X264DIR"
fi

# --- 2. zlib -> libz.a (clang.wasm) ------------------------------------------------------
if [ ! -f "$ZDIR/libz.a" ]; then
  echo "[ffmpeg] building zlib -> wasm (clang.wasm)"
  zsrc=(adler32 crc32 deflate inffast inflate inftrees trees zutil compress uncompr \
        gzclose gzlib gzread gzwrite)
  zobjs=()
  for s in "${zsrc[@]}"; do
    cwc "$ZDIR" -O2 -DHAVE_UNISTD_H -c "/work/$s.c" -o "/work/$s.o"
    zobjs+=("/work/$s.o")
  done
  cwar "$ZDIR" rcs /work/libz.a "${zobjs[@]}"
  [ -f "$ZDIR/libz.a" ] || { echo "[ffmpeg] zlib libz.a NOT built"; exit 1; }
fi

# --- 3. libx264 -> libx264.a (clang.wasm) ------------------------------------------------
# x264's hand-written configure cross-compiles C-only. Two reproducible perl patches teach
# its 2012-vintage config.sub + configure about the wasm/wasi target. We run configure with
# ccw.sh (clang.wasm as the probe cc), then compile the multilib (-8/-10 bit-depth) .c set
# with clang.wasm and archive with llvm-ar.
if [ ! -f "$X264DIR/libx264.a" ]; then
  echo "[ffmpeg] configuring + building libx264 -> wasm (clang.wasm)"
  ( cd "$X264DIR"
    if [ ! -f config.mak ]; then
      perl -0pi -e 's/(timestamp=.2012-12-06.\n)/$1\ncase "\$1" in wasm32-*) echo "wasm32-unknown-wasi"; exit 0;; esac\n/' config.sub
      perl -0pi -e 's/    \*\)\n        die "Unknown system \$host, edit the configure"\n        ;;\nesac/    wasi*|none*|unknown*)\n        SYS="LINUX"\n        libm="-lm"\n        ;;\n    *)\n        die "Unknown system \$host, edit the configure"\n        ;;\nesac/' configure
      grep -q 'wasi\*|none\*|unknown\*' configure || { echo "[ffmpeg] x264 configure patch FAILED"; exit 1; }
      CCW_CLANG="$CORE" CCW_SYSROOT="$SYSROOT" CCW_WORK="$BD" \
      CC="$SD/ccw.sh" AR="$CORE" RANLIB=: STRIP=: \
      ./configure \
        --host=wasm32-unknown-wasi \
        --disable-cli --enable-static \
        --disable-asm --disable-thread --disable-opencl \
        --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
        --disable-interlaced >/dev/null 2>&1 || { echo "[ffmpeg] x264 configure FAILED"; tail -30 config.log 2>/dev/null; exit 1; }
    fi
  )
  # Compile the x264 .c set with clang.wasm using the Makefile's object list. We derive each
  # object's bit-depth flags from its name suffix (-8 / -10) the same way x264's Makefile does.
  echo "[ffmpeg] compiling libx264 TUs (clang.wasm)"
  XCFLAGS=(-O2 -fno-stack-protector -std=gnu99 -D_GNU_SOURCE -fomit-frame-pointer
           -fno-tree-vectorize -fvisibility=hidden
           -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_PROCESS_CLOCKS
           -I/work/x264)
  xobjs=()
  # OBJS list from the Makefile (resolved): SRCS (no bit-depth) + SRCS_X (×{-8,-10}).
  # `make -n` only prints compile rules for objects that DON'T exist, so clear any stale .o
  # (and libx264.a) first, then read the full object list make would build.
  ( cd "$X264DIR"; find . -name '*.o' -delete 2>/dev/null; rm -f libx264.a
    make -n libx264.a 2>/dev/null ) | grep -oE '[a-zA-Z0-9_./-]+\.o' | sort -u > "$BD/x264-objs.txt" || true
  if [ ! -s "$BD/x264-objs.txt" ]; then echo "[ffmpeg] x264 object list empty"; exit 1; fi
  while read -r o; do
    o="${o#./}"
    case "$o" in
      *-8.o)  c="${o%-8.o}.c";  bd=(-DHIGH_BIT_DEPTH=0 -DBIT_DEPTH=8) ;;
      *-10.o) c="${o%-10.o}.c"; bd=(-DHIGH_BIT_DEPTH=1 -DBIT_DEPTH=10) ;;
      *.o)    c="${o%.o}.c";    bd=() ;;
    esac
    [ -f "$X264DIR/$c" ] || { echo "[ffmpeg] x264 src missing for $o ($c)"; exit 1; }
    cwc "$BD" "${XCFLAGS[@]}" ${bd[@]+"${bd[@]}"} -c "/work/x264/$c" -o "/work/x264/$o"
    xobjs+=("/work/x264/$o")
  done < "$BD/x264-objs.txt"
  cwar "$BD" rcs /work/x264/libx264.a "${xobjs[@]}"
  [ -f "$X264DIR/libx264.a" ] || { echo "[ffmpeg] libx264.a NOT built"; exit 1; }
fi

# --- 4. wasi POSIX shim (dup/pipe/mkstemp -> ENOSYS; dead paths) --------------------------
# Injected via `#include "wasi-shim.h"` in the generated config headers (NOT -include, which
# crashes clang.wasm). Lives in the ffmpeg tree root so the #include resolves.
SHIM="$FFDIR/wasi-shim.h"
cat > "$SHIM" <<'EOF'
/* wasi-shim: ENOSYS stubs for POSIX calls ffmpeg references but wasm32-wasi lacks.
   On dead code paths for the image2-demux/file-protocol/mp4-mux encode path.
   Injected via #include at the top of config.h + config_components.h. */
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

# --- 5. ffmpeg configure ONCE (ccw = clang.wasm probe cc) — CACHED ------------------------
if [ ! -f "$FFDIR/config.h" ]; then
  echo "[ffmpeg] configure via clang.wasm (one-time; ~15min, cached) — generates config.h + object list"
  ( cd "$FFDIR"
    CCW_CLANG="$CORE" CCW_SYSROOT="$SYSROOT" CCW_WORK="$BD" CCW_EXTRA_DIRS="$ZDIR::/zlib,$X264DIR::/x264" \
    ./configure \
      --cc="$SD/ccw.sh" --ld="$SD/ccw.sh" \
      --target-os=none --arch=wasm32 --enable-cross-compile \
      --tempprefix="$BD/cwtmp" \
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
      --extra-cflags="-I/zlib -I/x264" --extra-ldflags="-L/zlib -L/x264" \
      --extra-libs="-lx264 -lm" >/dev/null
  )
  [ -f "$FFDIR/config.h" ] || { echo "[ffmpeg] configure produced no config.h"; exit 1; }
  # Force-disable the host-only POSIX features configure mis-detects for the unknown wasm arch.
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
fi

# inject the shim into both generated config headers (idempotent)
for h in "$FFDIR/config.h" "$FFDIR/config_components.h"; do
  [ -f "$h" ] || continue
  grep -q '#include "wasi-shim.h"' "$h" || \
    perl -0pi -e 's/(#ifndef [A-Z_]*CONFIG[A-Z_]*\n#define [A-Z_]*CONFIG[A-Z_]*\n)/$1#include "wasi-shim.h"\n/' "$h"
done
grep -q '#include "wasi-shim.h"' "$FFDIR/config.h" || { echo "[ffmpeg] shim inject into config.h FAILED"; exit 1; }

# --- 6. harvest the curated ffmpeg .c compile list + per-file flags (make -n) -------------
# `make -n` prints every compile command. We capture the .c set; the common CFLAGS are
# rebuilt below for clang.wasm (we cannot reuse the host paths embedded in config.mak's CC).
echo "[ffmpeg] harvesting object list (make -n)"
( cd "$FFDIR"; make -n \
    libavformat/libavformat.a libavcodec/libavcodec.a libavfilter/libavfilter.a \
    libswscale/libswscale.a libswresample/libswresample.a libavutil/libavutil.a 2>/dev/null ) \
  | grep -oE '[a-zA-Z0-9_./-]+\.c\b' | grep -E '^(libavcodec|libavformat|libavfilter|libswscale|libswresample|libavutil)/' \
  | sort -u > "$BD/ff-c-list.txt" || true
[ -s "$BD/ff-c-list.txt" ] || { echo "[ffmpeg] ffmpeg .c list empty"; exit 1; }
echo "[ffmpeg] $(wc -l < "$BD/ff-c-list.txt") ffmpeg TUs to compile"

# --- 7. compile the curated ffmpeg .c set with clang.wasm --------------------------------
# CFLAGS mirror config.mak's CPPFLAGS/CFLAGS minus host paths; -I dirs are guest /work paths.
FFCFLAGS=(-O2 -fno-stack-protector -fomit-frame-pointer -std=c11
          -D_ISOC99_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE
          -D_POSIX_C_SOURCE=200112 -D_XOPEN_SOURCE=600 -DZLIB_CONST -DHAVE_AV_CONFIG_H
          -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_PROCESS_CLOCKS
          -I/work/ffmpeg-$FF_VER -I/work/zlib-$ZVER -I/work/x264
          -Wno-implicit-function-declaration -Wno-deprecated-declarations)
mkdir -p "$BD/ffobj"
ffobjs=()
n=0; total=$(wc -l < "$BD/ff-c-list.txt")
while read -r c; do
  n=$((n+1))
  o="ffobj/$(echo "$c" | tr '/' '_').o"
  if [ ! -f "$BD/$o" ]; then
    echo "[ffmpeg] cc ($n/$total) $c"
    cwc "$BD" "${FFCFLAGS[@]}" -c "/work/ffmpeg-$FF_VER/$c" -o "/work/$o" \
      || { echo "[ffmpeg] COMPILE FAILED: $c"; exit 1; }
  fi
  ffobjs+=("$BD/$o")
done < "$BD/ff-c-list.txt"

# --- 8. link the driver + all .o -> wb_encode.wasm (wasm-ld) ------------------------------
echo "[ffmpeg] compiling driver wb_encode.c (clang.wasm)"
cp -f "$SD/wb_encode.c" "$BD/wb_encode.c"
cwc "$BD" "${FFCFLAGS[@]}" -I/work/ffmpeg-$FF_VER/libavutil -c /work/wb_encode.c -o /work/wb_encode.o

echo "[ffmpeg] linking wb_encode.wasm (wasm-ld)"
# guest /work-relative object paths
gobjs=(/work/wb_encode.o)
for o in "${ffobjs[@]}"; do gobjs+=("/work/${o#$BD/}"); done
wasmtime run -C cache=y -W exceptions=y -W memory64=y \
  --dir "$SYSROOT::/usr" --dir "$BD::/work" \
  "$CORE" wasm-ld -m wasm32 --error-limit=0 --allow-undefined --gc-sections \
    -L"$RTLIB_G" -L"$LIBC_G" -L/work/zlib-$ZVER -L/work/x264 \
    "$LIBC_G/crt1-command.o" \
    "${gobjs[@]}" \
    -lx264 -lz \
    -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-getpid -lwasi-emulated-process-clocks \
    -lc "$RTLIB_G/libclang_rt.builtins.a" -lm \
    -o /work/wb_encode.wasm
cp -f "$BD/wb_encode.wasm" "$OUT"

[ -f "$OUT" ] || { echo "[ffmpeg] link FAILED — no wb_encode.wasm"; exit 1; }
echo "[ffmpeg] built $OUT ($(du -h "$OUT" | cut -f1))"
echo "$OUT" 1>&3
