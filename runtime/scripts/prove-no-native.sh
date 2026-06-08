#!/usr/bin/env bash
# EMPIRICAL PROOF (wb-fm0): the six language lanes compile untrusted source with NO native
# compiler. We shadow every native toolchain (rustc, cargo, go, tinygo, node, bun, javy, clang,
# zig, wasm-ld, llvm-ar, …) with a TRIPWIRE that logs + fails (exit 99) if invoked, then compile
# + run C / Rust / Zig / JS / TS / Go. If any lane secretly shelled a native compiler, the build
# would break and the tripwire log would be non-empty. Success + empty log = wasm-only compilation.
#
# Prereq: the toolchain wasms are already provisioned (compilers/*/build.sh, provision-rust.sh).
# wasmtime + the BEAM (elixir/erl) stay real — they are the host, not a compiler of user code.
set -euo pipefail
cd "$(dirname "$0")/.."

SHIM="$(mktemp -d)/shim"; LOG="$(mktemp)"
mkdir -p "$SHIM"; : > "$LOG"
trap 'rm -rf "$SHIM"; rm -f "$LOG"' EXIT

for t in rustc cargo cargo-component rustup go tinygo node bun javy clang clang++ zig gcc cc wasm-ld llvm-ar; do
  printf '#!/bin/sh\necho "NATIVE-INVOKED: %s $*" >> "%s"\nexit 99\n' "$t" "$LOG" > "$SHIM/$t"
  chmod +x "$SHIM/$t"
done
echo "[proof] tripwired: rustc cargo go tinygo node bun javy clang zig wasm-ld llvm-ar (and more)"
echo "[proof] wasmtime stays real: $(command -v wasmtime)"

cat > "$SHIM/_proof.exs" <<'EX'
defmodule P do
  alias Workbooks.PackageManager, as: PM
  def t(lang, src, want) do
    case PM.build(%{"name"=>"p#{:erlang.unique_integer([:positive])}","lang"=>lang,"src"=>src}) do
      {_n,^lang,{:ok,w,_}} ->
        out = PM.run(w,"",[]) |> to_string() |> String.trim()
        ok = String.contains?(out, want)
        IO.puts("#{if ok, do: "OK", else: "FAIL"} #{lang}: #{inspect(String.slice(out,0,50))}")
        ok
      {_n,^lang,e} -> IO.puts("FAIL #{lang} build: #{inspect(e)|>String.slice(0,90)}"); false
    end
  end
end
r = [
  P.t("c","#include <stdio.h>\nint main(){printf(\"C %d\\n\",6*7);return 0;}","C 42"),
  P.t("rust","use std::collections::HashMap;\nfn main(){let mut m=HashMap::new();m.insert(1,41);println!(\"RUST {}\",m[&1]+1);}","RUST 42"),
  P.t("zig","const std=@import(\"std\");\npub fn main() void { std.debug.print(\"ZIG {d}\\n\",.{6*7}); }","ZIG 42"),
  P.t("js","Javy.IO.writeSync(1,new TextEncoder().encode(\"JS \"+(6*7)+\"\\n\"));","JS 42"),
  P.t("ts","const x:number=6*7;Javy.IO.writeSync(1,new TextEncoder().encode(`TS ${x}\\n`));","TS 42"),
  P.t("go","package main\nimport \"fmt\"\nfunc main(){fmt.Printf(\"GO %d\\n\",6*7)}","GO 42"),
]
if Enum.all?(r), do: System.halt(0), else: System.halt(1)
EX

echo "[proof] compiling + running all six lanes with native toolchains tripwired…"
rm -f build/cache/*.wasm 2>/dev/null || true
PATH="$SHIM:$PATH" mix run "$SHIM/_proof.exs"
build_rc=$?

echo
if [ -s "$LOG" ]; then
  echo "🚨 FAIL: a native toolchain WAS invoked:"; cat "$LOG"; exit 1
elif [ "$build_rc" -ne 0 ]; then
  echo "🚨 FAIL: a lane did not produce correct output"; exit 1
else
  echo "✅ PROVEN: all six languages compiled + ran via wasm only — ZERO native compiler invocations."
fi
