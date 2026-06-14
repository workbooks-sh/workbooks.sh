# Exclude the heavy / external-resource tags by DEFAULT so plain `mix test`
# (and `wb dev test`) is a fast, deterministic gate that never hangs. These
# tags need a wasm toolchain (:build, :pallet, :serde, :simd, :rayon, :threads,
# :node) or live network (:netdeps) — without that environment they stall or
# fail. Run them explicitly: `mix test --include build` (or several --include
# flags) in a provisioned env. (:skip is the manual one-off opt-out.)
# Cap parallelism: several modules run heavy serial wasm/network work (the OQL
# kernel, ffmpeg.wasm, presign, brokers). With ExUnit's default max_cases
# (= schedulers_online, high on dev machines) the many async tests starve those,
# causing random timeouts — a DIFFERENT test fails each run while every test
# passes in isolation (wb-7twu). A moderate cap removes the starvation; the suite
# is plenty fast at this size.
ExUnit.start(
  exclude: [:skip, :build, :netdeps, :pallet, :node, :threads, :serde, :simd, :rayon],
  max_cases: min(System.schedulers_online(), 2)
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
