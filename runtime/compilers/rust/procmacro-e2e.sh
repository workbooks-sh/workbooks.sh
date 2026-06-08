#!/usr/bin/env bash
# PROOF (wb-vqx / wb-zq4 gap #1): a proc-macro crate that calls syn's `parse_macro_input!`
# — the exact construct serde_derive uses — COMPILES in-sandbox once the proc-macro subtree is
# built against a target_os-spoofed spec.
#
# ROOT CAUSE: syn 1.0.109 gates its `parse_macro_input` MODULE on
#   #[cfg(all(not(all(target_arch="wasm32", any(target_os="unknown", target_os="wasi"))), parsing, proc-macro))]
# Compiling syn for wasm32-wasi (os=wasi) EXCLUDES that module, so the #[macro_export]
# `parse_macro_input` macro never registers → consumers fail with "Unknown macro parse_macro_input".
# This is NOT an mrustc macro-surfacing bug (a generic cfg-gated #[macro_export] macro_rules imports
# fine). The fix is to compile the proc-macro subtree with os-name=linux (arch stays wasm32, codegen
# still emits wasm32-wasi) so the guard passes. compilers.ex applies this automatically to any crate
# under a proc-macro crate; this script reproduces it standalone for regression.
#
# Expected tail: "PROC-MACRO-E2E: parse_macro_input! compiled (gap #1 solved)".
# Prereq: the 174 lane prebuild (provision-rust-174.sh) — needs output-wasi-174/libstd.rlib.o +
# libproc_macro.rlib. Network needed to fetch the foundation crates.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRWASM="${MRWASM:-$SD/mrustc-root/mrustc_std.wasm}"
O="output-wasi-174"; D="$O/deps"
[ -f "$MRDIR/$O/libstd.rlib.o" ]      || { echo "[pm-e2e] 174 libstd not prebuilt — run provision-rust-174.sh"; exit 1; }
[ -f "$MRDIR/$O/libproc_macro.rlib" ] || { echo "[pm-e2e] libproc_macro.rlib missing — run provision-rust-174.sh"; exit 1; }

cd "$MRDIR"; mkdir -p .mrtmp "$D" poc-pm
trap 'rm -rf poc-pm "$D"/lib{proc_macro2,unicode_ident,quote,syn,myderive}.* 2>/dev/null || true' EXIT

# Spoofed target spec: wasm32-wasi with os-name=linux (the only line that differs).
cat > poc-pm/wasm32pm.spec <<'SPEC'
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
SPEC="poc-pm/wasm32pm.spec"

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 \
      --env MRUSTC_TARGET_VER=1.74 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }

fetch(){ # name version
  local n="$1" v="$2"
  [ -d "poc-pm/$n-$v" ] || { curl -fsSL "https://static.crates.io/crates/$n/$n-$v.crate" -o "poc-pm/$n-$v.crate"; tar -xzf "poc-pm/$n-$v.crate" -C poc-pm; }
}
fetch proc-macro2 1.0.69
fetch unicode-ident 1.0.12
fetch quote 1.0.33
fetch syn 1.0.109

echo "[pm-e2e] 1/5 unicode-ident" >&2
MR poc-pm/unicode-ident-1.0.12/src/lib.rs --crate-name unicode_ident --crate-type rlib -o "$D/libunicode_ident.rlib" -L "$O" -L "$D" --out-dir "$D" --target "$SPEC" --edition 2018 >&2
echo "[pm-e2e] 2/5 proc-macro2" >&2
MR poc-pm/proc-macro2-1.0.69/src/lib.rs --crate-name proc_macro2 --crate-type rlib -o "$D/libproc_macro2.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern unicode_ident="$D/libunicode_ident.rlib" \
  --out-dir "$D" --target "$SPEC" --edition 2021 --cfg 'feature="proc-macro"' >&2
echo "[pm-e2e] 3/5 quote" >&2
MR poc-pm/quote-1.0.33/src/lib.rs --crate-name quote --crate-type rlib -o "$D/libquote.rlib" -L "$O" -L "$D" \
  --extern proc_macro2="$D/libproc_macro2.rlib" --out-dir "$D" --target "$SPEC" --edition 2018 --cfg 'feature="proc-macro"' >&2
echo "[pm-e2e] 4/5 syn (full features)" >&2
MR poc-pm/syn-1.0.109/src/lib.rs --crate-name syn --crate-type rlib -o "$D/libsyn.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern proc_macro2="$D/libproc_macro2.rlib" \
  --extern quote="$D/libquote.rlib" --extern unicode_ident="$D/libunicode_ident.rlib" \
  --out-dir "$D" --target "$SPEC" --edition 2018 \
  --cfg 'feature="derive"' --cfg 'feature="parsing"' --cfg 'feature="printing"' \
  --cfg 'feature="clone-impls"' --cfg 'feature="proc-macro"' --cfg 'feature="full"' --cfg 'feature="extra-traits"' >&2

# The crate under test: a derive macro that calls parse_macro_input! (serde_derive's pattern).
cat > poc-pm/myderive.rs <<'RS'
extern crate proc_macro;
use proc_macro::TokenStream;
use syn::{parse_macro_input, DeriveInput};
use quote::quote;

#[proc_macro_derive(Hello)]
pub fn hello(input: TokenStream) -> TokenStream {
    let ast = parse_macro_input!(input as DeriveInput);
    let name = &ast.ident;
    let out = quote! { impl #name { fn hello() -> &'static str { "hi" } } };
    out.into()
}
RS
echo "[pm-e2e] 5/6 myderive (USES parse_macro_input!)" >&2
MR poc-pm/myderive.rs --crate-name myderive --crate-type proc-macro -o "$D/libmyderive.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern syn="$D/libsyn.rlib" \
  --extern quote="$D/libquote.rlib" --extern proc_macro2="$D/libproc_macro2.rlib" \
  --out-dir "$D" --target "$SPEC" --edition 2018 >&2
[ -f "$D/libmyderive.rlib.c" ] || { echo "[pm-e2e] FAILED: myderive did not emit C"; exit 1; }

# Real serde_derive 1.0.156 (last on syn 1.x). Built --crate-type proc-macro (NOT rlib — mrustc
# asserts "Procedural macros defined in non proc-macro crate" otherwise) at edition 2015 (it has a
# module literally named `try`, a reserved word in 2018+). Proves the whole real proc-macro crate
# compiles, not just our toy. (Executing the derive in a user compile is gap #2, not covered here.)
echo "[pm-e2e] 6/6 serde_derive 1.0.156 (crate-type proc-macro, ed2015)" >&2
fetch serde_derive 1.0.156
SDD=$(ls -d poc-pm/serde_derive-1.0.156)
MR "$SDD/src/lib.rs" --crate-name serde_derive --crate-type proc-macro -o "$D/libserde_derive.rlib" -L "$O" -L "$D" \
  --extern proc_macro="$O/libproc_macro.rlib" --extern proc_macro2="$D/libproc_macro2.rlib" \
  --extern quote="$D/libquote.rlib" --extern syn="$D/libsyn.rlib" \
  --out-dir "$D" --target "$SPEC" --edition 2015 >&2
trap 'rm -rf poc-pm "$D"/lib{proc_macro2,unicode_ident,quote,syn,myderive,serde_derive}.* 2>/dev/null || true' EXIT

[ -f "$D/libserde_derive.rlib.c" ] && echo "PROC-MACRO-E2E: parse_macro_input! + real serde_derive compiled (gap #1 solved)" \
  || { echo "[pm-e2e] FAILED: serde_derive did not emit C"; exit 1; }
