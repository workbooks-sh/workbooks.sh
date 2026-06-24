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
