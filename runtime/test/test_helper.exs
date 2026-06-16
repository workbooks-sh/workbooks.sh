# Exclude the heavy / external-resource tags by DEFAULT so plain `mix test`
# (and `work dev test`) is a fast, deterministic gate that never hangs. These
# tags need a wasm toolchain (:build, :wavelet, :pallet, :serde, :simd, :rayon,
# :threads, :node) or live network (:netdeps) — without that environment they stall
# or fail (e.g. :wavelet compiles/encodes via ffmpeg.wasm → clang_not_built without
# the toolchain). Run them explicitly: `mix test --include build` (or several --include
# flags) in a provisioned env. (:skip is the manual one-off opt-out.)
# Run SERIAL (max_cases: 1). Several modules run heavy wasm/network work (the OQL
# kernel, ffmpeg.wasm, presign, brokers) on shared resources (fixed TCP ports, the
# broker GenServer, the command registry). Under ANY parallelism two of them race:
# at the old high default they starved each other into random timeouts (wb-7twu),
# and even at max_cases:2 a seed-dependent pair could DEADLOCK/HANG the whole run
# (wb-ggyg, e.g. seed 259781 — an uninterruptible broker child/port wedge). Serial
# is deterministic (no races for any seed) AND faster here — these tests are
# serial-heavy, so the async gain is small while the contention overhead dominates
# (serial 68s vs 78s+ contended). PROVEN: `mix test --trace --seed 259781` (which
# forces serial) → 831 tests, 0 failures.
ExUnit.start(
  exclude: [:skip, :build, :wavelet, :netdeps, :pallet, :node, :threads, :serde, :simd, :rayon],
  max_cases: 1
)

# NOTE: We deliberately do NOT start the full OTP application here.
# `Workbooks.Application` binds network ports (Bandit/control-plane), which
# would make `mix test` flaky and refuse to run in parallel / CI.
#
# Tests that need a running service should start only that service in a
# per-module `setup` (or `setup_all`) block, e.g.:
#
#     setup do
#       {:ok, _pid} = Workbooks.OQL.start_link(nil)
#       :ok
#     end
#
# Pure-function modules (like Workbooks.CommandRegistry.list/0) need no setup.
