#!/usr/bin/env bash
# Provision the monocypher (crypto) lane: fetch source, stage src/{monocypher.c,monocypher.h,driver.c} for
# build_c_dir. driver = Ed25519 keygen+sign+verify+tamper + Blake2b. Idempotent. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="4.0.2"; SHA="38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c"
exec 3>&1 1>&2
if [ -f "$SRC/monocypher.c" ] && [ -f "$SRC/driver.c" ]; then echo "[monocypher] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/monocypher-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[monocypher] fetch $VER"; curl -fsSL "https://monocypher.org/download/monocypher-$VER.tar.gz" -o "$TGZ" || curl -fsSL "https://github.com/LoupVaillant/Monocypher/releases/download/$VER/monocypher-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[monocypher] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/monocypher-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
cp "$SD/monocypher-$VER/src/monocypher.c" "$SD/monocypher-$VER/src/monocypher.h" "$SRC/"; rm -rf "$SD/monocypher-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "monocypher.h"
int main(void){
  uint8_t seed[32]; for(int i=0;i<32;i++) seed[i]=(uint8_t)(i*7+1);
  uint8_t sk[64], pk[32]; crypto_eddsa_key_pair(sk, pk, seed);
  const char* msg = "workbooks forge crypto"; size_t n = strlen(msg);
  uint8_t sig[64]; crypto_eddsa_sign(sig, sk, (const uint8_t*)msg, n);
  int ok = crypto_eddsa_check(sig, pk, (const uint8_t*)msg, n);
  uint8_t bad[64]; memcpy(bad, sig, 64); bad[0]^=1;
  int tampered = crypto_eddsa_check(bad, pk, (const uint8_t*)msg, n);
  uint8_t h[32]; crypto_blake2b(h, 32, (const uint8_t*)msg, n);
  printf("sign_verify=%d tamper_rejected=%d blake2b0=%02x\n", ok==0, tampered!=0, h[0]);
  return 0;
}
C
echo "[monocypher] staged -> $SRC"; echo "$SRC" 1>&3
