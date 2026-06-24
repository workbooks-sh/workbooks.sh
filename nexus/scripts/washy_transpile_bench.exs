# Washy interp-vs-transpile benchmark — the speed-ceiling measurement for the wasm→BEAM spike.
#
#   mix run scripts/washy_transpile_bench.exs
#
# Compares the pure-Elixir tree-walking interpreter (Nexus.Washy.call) against the wasm→BEAM
# transpiler (Nexus.Washy.Transpile.compile → native BEAM fn) on a HOT LOOP: sumto(n), which is a
# real block/loop/br_if/br kernel mutating a local each iteration (≈ 8 wasm ops × n iterations).
#
# Reports wall-clock for both backends + the speedup factor. This is the number that decides whether
# CPython-class interpreters can run at viable speed on the dense BEAM lane.

import Bitwise
alias Nexus.Washy
alias Nexus.Washy.Transpile

# sumto(n) = n + (n-1) + ... + 1 — block/loop/br_if/br + i32.eqz/add/sub + a mutable local.
sumto = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0,
  7, 9, 1, 5, 115, 117, 109, 116, 111, 0, 0,
  10, 35, 1, 33, 1, 1, 127,
  2, 64, 3, 64, 32, 0, 69, 13, 1, 32, 1, 32, 0, 106, 33, 1, 32, 0, 65, 1, 107, 33, 0, 12, 0, 11, 11, 32, 1, 11
>>

{:ok, mod} = Washy.decode(sumto)
{:ok, jit} = Transpile.compile(mod, "sumto")

# correctness sanity (the bench is meaningless if they disagree)
n = 20_000
expected = div(n * (n + 1), 2) &&& 0xFFFFFFFF
^expected = Washy.call(mod, "sumto", [n])
^expected = jit.([n])

# each call runs ~8*n wasm ops; pick iters so total work is comparable + the timer is meaningful.
iters = 200

time = fn fun ->
  # warmup
  fun.()
  {us, _} = :timer.tc(fn -> for _ <- 1..iters, do: fun.() end)
  us / iters
end

interp_us = time.(fn -> Washy.call(mod, "sumto", [n]) end)
jit_us = time.(fn -> jit.([n]) end)

ops = 8 * n

IO.puts("""

Washy wasm→BEAM transpiler — hot-loop benchmark
  kernel        : sumto(#{n})  (≈ #{ops} wasm ops / call, real block/loop/br_if/br + mutable local)
  iterations    : #{iters}
  ---------------------------------------------
  interp        : #{Float.round(interp_us, 1)} µs/call   (#{Float.round(ops / interp_us, 1)} Mops/s)
  transpile     : #{Float.round(jit_us, 2)} µs/call   (#{Float.round(ops / jit_us, 1)} Mops/s)
  ---------------------------------------------
  SPEEDUP       : #{Float.round(interp_us / jit_us, 1)}×
""")

# ── MEMORY-HEAVY kernel: write an i32 array into linear memory, then sum it back. ──────────────────
# fillsum(n): loop1 stores mem[i*4]=i for i in 0..n-1; loop2 sums mem[i*4]. Hits the packed `:atomics`
# linear memory on every iteration (store + load), so this measures the SAME byte-access path the
# interpreter uses — the honest speed for interpreter-class (compute+memory) workloads. 16 pages = 1MB.
fillsum = <<
  0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 16,
  7, 11, 1, 7, 102, 105, 108, 108, 115, 117, 109, 0, 0, 10, 87, 1, 85, 1, 2, 127,
  65, 0, 33, 1, 2, 64, 3, 64, 32, 1, 32, 0, 70, 13, 1, 32, 1, 65, 2, 116, 32, 1, 54, 2, 0,
  32, 1, 65, 1, 106, 33, 1, 12, 0, 11, 11, 65, 0, 33, 2, 65, 0, 33, 1,
  2, 64, 3, 64, 32, 1, 32, 0, 70, 13, 1, 32, 2, 32, 1, 65, 2, 116, 40, 2, 0, 106, 33, 2,
  32, 1, 65, 1, 106, 33, 1, 12, 0, 11, 11, 32, 2, 11
>>

{:ok, mmod} = Washy.decode(fillsum)
{:ok, mjit} = Transpile.compile(mmod, "fillsum")

mn = 5_000
mexpected = Enum.sum(0..(mn - 1)) &&& 0xFFFFFFFF
^mexpected = Washy.call(mmod, "fillsum", [mn])
^mexpected = mjit.([mn])

miters = 100
minterp_us = time.(fn -> Washy.call(mmod, "fillsum", [mn]) end)
mjit_us = time.(fn -> mjit.([mn]) end)
# ~14 wasm ops per element across the two loops (store loop ~9, sum loop ~10, minus shared), × n.
mops = 19 * mn

IO.puts("""
Washy wasm→BEAM transpiler — MEMORY-HEAVY benchmark
  kernel        : fillsum(#{mn})  (write then sum an i32 array in linear memory — store+load/elem)
  iterations    : #{miters}
  ---------------------------------------------
  interp        : #{Float.round(minterp_us, 1)} µs/call   (#{Float.round(mops / minterp_us, 1)} Mops/s)
  transpile     : #{Float.round(mjit_us, 2)} µs/call   (#{Float.round(mops / mjit_us, 1)} Mops/s)
  ---------------------------------------------
  SPEEDUP       : #{Float.round(minterp_us / mjit_us, 1)}×
""")
