#!/usr/bin/env bash
# work python lane — an interpreter-in-wasm (the Go/yaegi pattern). CPython 3.12 compiled to
# wasm32-wasi (VMware webassembly-language-runtimes) is the lane's artifact: it runs a user `.py`
# (mounted) and talks stdin→stdout, the same command shape as the JS lane. There is nothing
# per-program to compile — the source is the run-time input.
#
# Reproduce (vendor the interpreter) from this dir:
#   curl -fsSL -o pythonrun.wasm \
#     'https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python%2F3.12.0%2B20231211-040d5a6/python-3.12.0.wasm'
#
# Driver: Nexus.Compilers.Python.python_compile_to_wasm/2 returns this interpreter; the runner mounts
# the unit's source + feeds its stdin.
set -euo pipefail
echo "[python] pythonrun.wasm is a prebuilt CPython-wasi interpreter (see header). Nothing to compile."
