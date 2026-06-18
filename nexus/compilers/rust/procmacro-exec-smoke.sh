#!/usr/bin/env bash
# PROOF (wb-5dd / wb-zq4 gap #2): a compiled proc-macro runs as a standalone WASM "server" that
# speaks mrustc's token protocol — boots, reads a TokenStream, EXECUTES the macro, writes the
# expansion back. This de-risks the exec-bridge: the eventual host import `wb_proc_macro_expand`
# does exactly what the final step here does — `wasmtime run server.wasm <MacroName> < in > out`.
#
# Pipeline:
#   1. mrustc.wasm builds proc-macro2/quote/unicode-ident (spoofed spec) + a derive crate
#      (--crate-type proc-macro → mrustc injects `fn main(){ proc_macro::main(&MACROS) }`).
#      NOTE: mrustc throws AFTER emitting the .c (it tries to spawn gcc to link, which wasi forbids);
#      that throw is expected — we only need the .c, then link it ourselves.
#   2. clang.wasm compiles each .c → .o.
#   3. wasm-ld links a RUNNABLE command wasm (crt1 + libstd + libproc_macro server loop).
#   4. Feed a crafted TokenStream (`struct Bar;`) on stdin, assert the expansion comes back.
#
# Expected tail: "PROC-MACRO-EXEC: server ran the derive in-sandbox (gap #2 server half proven)".
# Prereq: provision-rust-174.sh (output-wasi-174/libstd.rlib.o + libproc_macro.rlib.o) + the wasi
# shim with args_get/args_sizes_get (compilers/zig/wasi_shim.c). Network to fetch the crates.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
COMPILERS="$(cd "$SD/.." && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRWASM="${MRWASM:-$SD/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
SHIM="${SHIM:-$COMPILERS/zig/wasi_shim.c}"
O="output-wasi-174"; D="$O/deps"
[ -f "$MRDIR/$O/libstd.rlib.o" ]      || { echo "[exec-smoke] 174 libstd not prebuilt — run provision-rust-174.sh"; exit 1; }
[ -f "$MRDIR/$O/libproc_macro.rlib.o" ] || { echo "[exec-smoke] libproc_macro.rlib.o missing — run provision-rust-174.sh"; exit 1; }

cd "$MRDIR"; mkdir -p .mrtmp .cctmp "$D" poc-pmx
trap 'rm -rf poc-pmx "$D"/lib{proc_macro2,unicode_ident,quote,myderive}.* "$D"/myderive_server.wasm 2>/dev/null || true' EXIT

cat > poc-pmx/wasm32pm.spec <<'SPEC'
[target]
family = ""
os-name = "linux"
env-name = ""

[backend.c]
variant = "gnu"
emulate-i128 = true
target = "wasm32-wasi"
compiler-opts = ["-ffunction-sections",]
linker-opts-pre = []
linker-opts-post = ["-Wl,--gc-sections",]

[arch]
name = "wasm32"
pointer-bits = 32
is-big-endian = false
has-atomic-u8 = true
has-atomic-u16 = false
has-atomic-u32 = true
has-atomic-u64 = false
has-atomic-ptr = true
alignments = { u16 = 2, u32 = 4, u64 = 8, u128 = 16, f32 = 4, f64 = 8, ptr = 4 }
SPEC
SPEC="poc-pmx/wasm32pm.spec"

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 \
      --env MRUSTC_TARGET_VER=1.74 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" --dir "$MRDIR/poc-pmx::/src" "$MRWASM" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }

fetch(){ local n="$1" v="$2"; [ -d "poc-pmx/$n-$v" ] || { curl -fsSL "https://static.crates.io/crates/$n/$n-$v.crate" -o "poc-pmx/$n-$v.crate"; tar -xzf "poc-pmx/$n-$v.crate" -C poc-pmx; }; }
fetch proc-macro2 1.0.69
fetch unicode-ident 1.0.12
fetch quote 1.0.33

echo "[exec-smoke] 1/6 foundation crates (mrustc → .c, spoofed spec)" >&2
MR /src/unicode-ident-1.0.12/src/lib.rs --crate-name unicode_ident --crate-type rlib -o "$D/libunicode_ident.rlib" -L "$O" -L "$D" --out-dir "$D" --target "$SPEC" --edition 2018 >&2
MR /src/proc-macro2-1.0.69/src/lib.rs --crate-name proc_macro2 --crate-type rlib -o "$D/libproc_macro2.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern unicode_ident="$D/libunicode_ident.rlib" --out-dir "$D" --target "$SPEC" --edition 2021 --cfg 'feature="proc-macro"' >&2
MR /src/quote-1.0.33/src/lib.rs --crate-name quote --crate-type rlib -o "$D/libquote.rlib" -L "$O" -L "$D" \
  --extern proc_macro2="$D/libproc_macro2.rlib" --out-dir "$D" --target "$SPEC" --edition 2018 --cfg 'feature="proc-macro"' >&2

# A derive macro whose body is observable: emits the input's stringified length as a literal.
cat > poc-pmx/myderive.rs <<'RS'
extern crate proc_macro;
use proc_macro::TokenStream;
#[proc_macro_derive(Hello)]
pub fn hello(input: TokenStream) -> TokenStream {
    let n = input.to_string().len();
    format!("impl Foo {{ fn hello() -> u32 {{ {} }} }}", n).parse().unwrap()
}
RS
echo "[exec-smoke] 2/6 derive crate (--crate-type proc-macro; mrustc gcc-spawn throw is expected)" >&2
MR /src/myderive.rs --crate-name myderive --crate-type proc-macro -o "$D/libmyderive.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern proc_macro2="$D/libproc_macro2.rlib" --extern quote="$D/libquote.rlib" \
  --out-dir "$D" --target "$SPEC" --edition 2018 >&2 2>/dev/null || true
[ -f "$D/libmyderive.rlib.c" ] || { echo "[exec-smoke] FAILED: derive .c not emitted"; exit 1; }

echo "[exec-smoke] 3/6 clang each .c → .o" >&2
CFLAGS=(--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier)
for c in unicode_ident proc_macro2 quote myderive; do
  CL clang "${CFLAGS[@]}" -c "/work/$D/lib$c.rlib.c" -o "/work/$D/lib$c.rlib.o" >&2
done

echo "[exec-smoke] 4/6 ensure wasi shim has args_get (rebuild from source)" >&2
cp "$SHIM" "$O/wasi_shim.c"
CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -w -c "/work/$O/wasi_shim.c" -o "/work/$O/wasi_shim.o" >&2

echo "[exec-smoke] 5/6 wasm-ld → runnable proc-macro server wasm" >&2
LIBSTD=$(ls "$O"/*.rlib.o | sed 's#^#/work/#')
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o \
  /work/$D/libmyderive.rlib.o /work/$D/libproc_macro2.rlib.o /work/$D/libquote.rlib.o /work/$D/libunicode_ident.rlib.o \
  $LIBSTD "/work/$O/wasi_shim.o" "/work/$O/ustub.o" \
  -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a \
  -o "/work/$D/myderive_server.wasm" >&2
[ -f "$D/myderive_server.wasm" ] || { echo "[exec-smoke] FAILED: server did not link"; exit 1; }

echo "[exec-smoke] 6/6 run server: feed TokenStream \`struct Bar;\` to macro 'Hello'" >&2
python3 - <<'PY'
def t(tag, s=b""): return bytes([tag, len(s)]) + s
blob = t(2,b"struct") + t(2,b"Bar") + t(1,b";") + bytes([0])   # Ident Ident Symbol EOS
open("poc-pmx/ts_in.bin","wb").write(blob)
PY
wasmtime run -W exceptions=y "$D/myderive_server.wasm" Hello < poc-pmx/ts_in.bin > poc-pmx/ts_out.bin 2>poc-pmx/ts_err.txt
# The expansion must contain the Ident "impl", "u32", and a non-zero numeric literal (input length).
if grep -aq "impl" poc-pmx/ts_out.bin && grep -aq "u32" poc-pmx/ts_out.bin; then
  echo "PROC-MACRO-EXEC: server ran the derive in-sandbox (gap #2 server half proven)"
else
  echo "[exec-smoke] FAILED: output did not contain expected expansion"; xxd poc-pmx/ts_out.bin | head; cat poc-pmx/ts_err.txt; exit 1
fi
