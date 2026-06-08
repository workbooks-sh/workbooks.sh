#!/usr/bin/env bash
# PROOF (wb-v3d / wb-zq4 gap #2 — THE FULL EXEC-BRIDGE): a user crate that does `#[derive(Hello)]`
# compiles end-to-end with the derive EXECUTED in-sandbox. mrustc_pm.wasm runs under Wasmex (which
# enables the wasm exception proposal), serialises the derive input, and calls the host import
# workbooks.pm_expand; the host (Workbooks.ProcMacroHost) runs the proc-macro SERVER wasm, returns
# the expansion, and mrustc consumes it. Airtight: the user defines a bare `struct Foo;` whose only
# `impl` (needed by `Foo::hello()`) comes from the derive applied to `struct Bar` — so a clean
# compile is only possible if the proc-macro actually ran.
#
# Expected tail: "PROC-MACRO-BRIDGE: derive executed in-sandbox, user crate compiled (gap #2 DONE)".
# Prereq: provision-rust-174.sh, build.sh (produces mrustc_pm.wasm), provision-wasmex-pm.sh (Wasmex
# with exceptions). Network to fetch the foundation crates. Run from runtime/compilers/rust.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$(cd "$SD/../.." && pwd)"
COMPILERS="$(cd "$SD/.." && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRSTD="${MRSTD:-$SD/mrustc-root/mrustc_std.wasm}"
MRPM="${MRPM:-$SD/mrustc-root/mrustc_pm.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
SHIM="${SHIM:-$COMPILERS/zig/wasi_shim.c}"
O="output-wasi-174"; D="$O/deps"
[ -f "$MRPM" ]                       || { echo "[bridge] mrustc_pm.wasm missing — run build.sh"; exit 1; }
[ -f "$MRDIR/$O/libproc_macro.rlib.o" ] || { echo "[bridge] run provision-rust-174.sh"; exit 1; }

cd "$MRDIR"; mkdir -p .mrtmp .cctmp "$D" poc-br
trap 'rm -rf poc-br "$D"/lib{proc_macro2,unicode_ident,quote,myderive}.* "$D"/myderive_server.wasm* "$O/user.rs" "$O/user.c" "$O/user.hir" 2>/dev/null || true' EXIT

cat > poc-br/wasm32pm.spec <<'SPEC'
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
SPEC="poc-br/wasm32pm.spec"

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 --env MRUSTC_TARGET_VER=1.74 \
      --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" \
      --dir "$MRDIR/poc-br::/src" "$MRSTD" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }
fetch(){ local n="$1" v="$2"; [ -d "poc-br/$n-$v" ] || { curl -fsSL "https://static.crates.io/crates/$n/$n-$v.crate" -o "poc-br/$n-$v.crate"; tar -xzf "poc-br/$n-$v.crate" -C poc-br; }; }
fetch proc-macro2 1.0.69; fetch unicode-ident 1.0.12; fetch quote 1.0.33

echo "[bridge] 1/4 build the derive crate + its server wasm" >&2
MR /src/unicode-ident-1.0.12/src/lib.rs --crate-name unicode_ident --crate-type rlib -o "$D/libunicode_ident.rlib" -L "$O" -L "$D" --out-dir "$D" --target "$SPEC" --edition 2018 >&2
MR /src/proc-macro2-1.0.69/src/lib.rs --crate-name proc_macro2 --crate-type rlib -o "$D/libproc_macro2.rlib" -L "$O" -L "$D" --extern proc_macro="$O/libproc_macro.rlib" --extern unicode_ident="$D/libunicode_ident.rlib" --out-dir "$D" --target "$SPEC" --edition 2021 --cfg 'feature="proc-macro"' >&2
MR /src/quote-1.0.33/src/lib.rs --crate-name quote --crate-type rlib -o "$D/libquote.rlib" -L "$O" -L "$D" --extern proc_macro2="$D/libproc_macro2.rlib" --out-dir "$D" --target "$SPEC" --edition 2018 --cfg 'feature="proc-macro"' >&2
cat > poc-br/myderive.rs <<'RS'
extern crate proc_macro;
use proc_macro::TokenStream;
#[proc_macro_derive(Hello)]
pub fn hello(input: TokenStream) -> TokenStream {
    let n = input.to_string().len() as u32;
    format!("impl Foo {{ pub fn hello() -> u32 {{ {} }} }}", n).parse().unwrap()
}
RS
MR /src/myderive.rs --crate-name myderive --crate-type proc-macro -o "$D/libmyderive.rlib" -L "$O" -L "$D" --extern proc_macro="$O/libproc_macro.rlib" --extern proc_macro2="$D/libproc_macro2.rlib" --extern quote="$D/libquote.rlib" --out-dir "$D" --target "$SPEC" --edition 2018 >&2 2>/dev/null || true
CF="--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier"
for c in unicode_ident proc_macro2 quote myderive; do CL clang $CF -c "/work/$D/lib$c.rlib.c" -o "/work/$D/lib$c.rlib.o" >&2; done
cp "$SHIM" "$O/wasi_shim.c"; CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -w -c "/work/$O/wasi_shim.c" -o "/work/$O/wasi_shim.o" >&2
LIBSTD=$(ls "$O"/*.rlib.o | sed 's#^#/work/#')
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 /usr/lib/wasm32-wasip1/crt1-command.o \
  /work/$D/libmyderive.rlib.o /work/$D/libproc_macro2.rlib.o /work/$D/libquote.rlib.o /work/$D/libunicode_ident.rlib.o \
  $LIBSTD "/work/$O/wasi_shim.o" "/work/$O/ustub.o" -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a \
  -o "/work/$D/myderive_server.wasm" >&2
cp "$D/libmyderive.rlib.hir" "$D/myderive_server.wasm.hir"   # crate metadata sidecar for --extern

echo "[bridge] 2/4 write the user crate (bare struct Foo; derive on Bar supplies impl Foo)" >&2
cat > "$O/user.rs" <<'RS'
use myderive::Hello;
struct Foo;
#[derive(Hello)]
struct Bar;
fn main() { let _x: u32 = Foo::hello(); }
RS

echo "[bridge] 3/4 run the user compile via mrustc_pm.wasm under Wasmex (host runs the derive)" >&2
cat > poc-br/run.exs <<'EX'
[pm, mrdir, server] = System.argv()
args = ["output-wasi-174/user.rs", "--crate-name", "user", "--crate-type", "bin",
        "-L", "output-wasi-174", "-L", "output-wasi-174/deps",
        "--extern", "myderive=" <> server,
        "--out-dir", "output-wasi-174", "--target", "wasm32-wasi", "--edition", "2018"]
env = %{"MRUSTC_TARGET_VER" => "1.74", "STD_ENV_ARCH" => "wasm32", "TMPDIR" => "/tmp"}
case Workbooks.ProcMacroHost.run_mrustc(pm, args, mrdir, env, timeout: 180_000) do
  {:ok, _} ->
    if File.regular?(Path.join(mrdir, "output-wasi-174/user.c")), do: IO.puts("BRIDGE_OK"), else: IO.puts("BRIDGE_NO_C")
  {:error, e} -> IO.puts("BRIDGE_ERR " <> String.slice(inspect(e), 0, 300))
end
EX
cd "$RUNTIME"
RES=$(WASMEX_BUILD=1 mix run "$MRDIR/poc-br/run.exs" "$MRPM" "$MRDIR" "output-wasi-174/deps/myderive_server.wasm" 2>/dev/null | grep -E "^BRIDGE" | tail -1)
echo "[bridge] 4/4 result: $RES" >&2
case "$RES" in
  BRIDGE_OK) echo "PROC-MACRO-BRIDGE: derive executed in-sandbox, user crate compiled (gap #2 DONE)" ;;
  *) echo "[bridge] FAILED: $RES"; exit 1 ;;
esac
