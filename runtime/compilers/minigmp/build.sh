#!/usr/bin/env bash
# Provision the mini-gmp (arbitrary-precision integer math) lane: fetch GMP, extract the single-file mini-gmp
# (a GMP-compatible mpz_* subset), stage src/{mini-gmp.c,mini-gmp.h,driver.c} for build_c_dir. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="6.3.0"; SHA="a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
exec 3>&1 1>&2
if [ -f "$SRC/mini-gmp.c" ] && [ -f "$SRC/driver.c" ]; then echo "[minigmp] up to date"; echo "$SRC" 1>&3; exit 0; fi
TXZ="$SD/gmp-$VER.tar.xz"
[ -f "$TXZ" ] || { echo "[minigmp] fetch gmp $VER"; curl -fsSL "https://ftp.gnu.org/gnu/gmp/gmp-$VER.tar.xz" -o "$TXZ"; }
echo "$SHA  $TXZ" | shasum -a 256 -c - || { echo "[minigmp] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/gmp-$VER"; mkdir -p "$SRC"; tar xf "$TXZ" -C "$SD"
cp "$SD/gmp-$VER/mini-gmp/mini-gmp.c" "$SD/gmp-$VER/mini-gmp/mini-gmp.h" "$SRC/"; rm -rf "$SD/gmp-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include "mini-gmp.h"
int main(void){
  mpz_t a, r; mpz_init(a); mpz_init(r);
  mpz_set_ui(a, 2); mpz_pow_ui(r, a, 200);
  char* s = mpz_get_str(NULL, 10, r); printf("pow=%s\n", s);
  mpz_set_ui(r, 1); for(unsigned i=2;i<=30;i++) mpz_mul_ui(r, r, i);
  char* f = mpz_get_str(NULL, 10, r); printf("fact=%s\n", f);
  return 0;
}
C
echo "[minigmp] staged -> $SRC"; echo "$SRC" 1>&3
