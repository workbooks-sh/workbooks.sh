#!/usr/bin/env bash
# PROOF (wb-dk3 / wb-iht): the BEAM-offload pattern applied to build.rs. A build script is just a
# Rust program — so we COMPILE it with our own lane, RUN it in the wasm sandbox, and parse its
# `cargo:` directives in (pretend) Elixir. Here we prove the loop end-to-end: a crate whose
# conditional compilation depends ENTIRELY on a cfg its build.rs emits.
#
#   build.rs:  println!("cargo:rustc-cfg=have_answer");
#   lib.rs:    #[cfg(have_answer)] pub fn answer()->i32 {42}   (else 0)
#   user:      prints bcfg::answer()
#
# Without running build.rs, `have_answer` is unset → answer()==0. The loop runs build.rs in-sandbox,
# extracts the cfg, compiles the crate WITH it, and the program prints 42 — proving build-script
# execution is fully BEAM-offloadable (orchestrate + parse), no native toolchain, no new NIF.
#
# Expected tail: "BUILDRS-SMOKE: build.rs cfg applied in-sandbox -> 42 (gap wb-iht is BEAM-soluble)".
# Prereq: provision-rust-174.sh (1.74 libstd + shims). Run from runtime/compilers/rust.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
COMPILERS="$(cd "$SD/.." && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRSTD="${MRSTD:-$SD/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
O="output-wasi-174"; D="$O/deps"
[ -f "$MRDIR/$O/libstd.rlib.o" ] || { echo "[buildrs] 174 libstd not prebuilt — run provision-rust-174.sh"; exit 1; }

cd "$MRDIR"; mkdir -p .mrtmp .cctmp "$D" poc-brs poc-brs/out
trap 'rm -rf poc-brs "$D"/lib{bcfg,brsbuild}.* "$O"/brs_user.* 2>/dev/null || true' EXIT

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 --env MRUSTC_TARGET_VER=1.74 \
      --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" \
      --dir "$MRDIR/poc-brs::/src" "$MRSTD" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }
CF="--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier"

# ---- the synthetic crate ----
cat > poc-brs/build.rs <<'RS'
fn main() {
    // the kind of thing real build scripts do: emit a cfg the crate compiles against
    println!("cargo:rustc-cfg=have_answer");
}
RS
cat > poc-brs/lib.rs <<'RS'
#[cfg(have_answer)]
pub fn answer() -> i32 { 42 }
#[cfg(not(have_answer))]
pub fn answer() -> i32 { 0 }
RS
cat > poc-brs/user.rs <<'RS'
fn main() { println!("ANSWER={}", bcfg::answer()); }
RS

echo "[buildrs] 1/5 compile build.rs → runnable wasm (it's just a Rust bin)" >&2
MR /src/build.rs --crate-name brsbuild --crate-type bin -L "$O" --out-dir "$D" --target wasm32-wasi --edition 2018 >&2
CL clang $CF -c "/work/$D/brsbuild.c" -o "/work/$D/brsbuild.o" >&2
LIBSTD=$(ls "$O"/*.rlib.o | sed 's#^#/work/#')
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o /work/$D/brsbuild.o $LIBSTD \
  "/work/$O/wasi_shim.o" "/work/$O/ustub.o" -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a \
  -o "/work/$D/brsbuild.wasm" >&2

echo "[buildrs] 2/5 RUN build.rs in-sandbox, capture cargo: directives (OUT_DIR pre-opened, writable)" >&2
DIRECTIVES=$(wasmtime run -W exceptions=y --env OUT_DIR=/out --env "TARGET=wasm32-wasi" --env "HOST=wasm32-wasi" \
  --env "CARGO_CFG_TARGET_ARCH=wasm32" --env "PROFILE=release" --env "OPT_LEVEL=1" \
  --dir "$MRDIR/poc-brs/out::/out" "$D/brsbuild.wasm" 2>/dev/null)
echo "[buildrs]   build.rs said: $DIRECTIVES" >&2

echo "[buildrs] 3/5 parse cargo:rustc-cfg (the Elixir side does this)" >&2
CFGS=""
while IFS= read -r line; do
  case "$line" in
    cargo:rustc-cfg=*) CFGS="$CFGS --cfg ${line#cargo:rustc-cfg=}" ;;
  esac
done <<< "$DIRECTIVES"
echo "[buildrs]   extracted cfgs:$CFGS" >&2
[ -n "$CFGS" ] || { echo "[buildrs] FAILED: no rustc-cfg parsed"; exit 1; }

echo "[buildrs] 4/5 compile the crate WITH the build-script cfg + link the user program" >&2
# shellcheck disable=SC2086
MR /src/lib.rs --crate-name bcfg --crate-type rlib -o "$D/libbcfg.rlib" -L "$O" -L "$D" --out-dir "$D" --target wasm32-wasi --edition 2018 $CFGS >&2
CL clang $CF -c "/work/$D/libbcfg.rlib.c" -o "/work/$D/libbcfg.rlib.o" >&2
cp poc-brs/user.rs "$O/brs_user.rs"
MR "$O/brs_user.rs" --crate-name brs_user --crate-type bin --extern bcfg="$D/libbcfg.rlib" -L "$O" -L "$D" --out-dir "$O" --target wasm32-wasi --edition 2018 >&2
CL clang $CF -c "/work/$O/brs_user.c" -o "/work/$O/brs_user.o" >&2
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o /work/$O/brs_user.o /work/$D/libbcfg.rlib.o $LIBSTD \
  "/work/$O/wasi_shim.o" "/work/$O/ustub.o" -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a \
  -o "/work/$O/brs_user.wasm" >&2

echo "[buildrs] 5/5 run the user program" >&2
OUT=$(wasmtime run -W exceptions=y "$O/brs_user.wasm" 2>/dev/null)
echo "[buildrs]   program printed: $OUT" >&2
if [ "$OUT" = "ANSWER=42" ]; then
  echo "BUILDRS-SMOKE: build.rs cfg applied in-sandbox -> 42 (gap wb-iht is BEAM-soluble)"
else
  echo "[buildrs] FAILED: expected ANSWER=42, got '$OUT'"; exit 1
fi
