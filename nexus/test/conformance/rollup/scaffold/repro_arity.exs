# 2-second repro of the rollup Chunk-constructor gap: a 15-param constructor whose 10th param arrives
# undefined (CTOR param=U). Hypothesis: arg-arity truncation on boxed `new` (wrapperArgc/__callN cap).
# Self-validating: each cell is D (defined arg) or U (dropped) — a cutoff to U = the bug; all D = no bug.
src = """
var Cap = class {
  constructor(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15) {
    this.r = [a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15].map(function(x){return x===undefined?'U':'D'}).join('');
  }
};
function mk() { return new Cap(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15); }
console.log('NEW_CAPTURED ' + mk().r);
var top = new Cap(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15);
console.log('NEW_TOPLEVEL ' + top.r);
function f15(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15) {
  return [a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15].map(function(x){return x===undefined?'U':'D'}).join('');
}
console.log('FN15 ' + f15(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15));
"""
case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} -> case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true) do
    {:ok, out} -> IO.puts(String.replace(out, ~r/\e\[[0-9;]*m/, "") |> String.trim())
    e -> IO.puts("RUN-ERR #{inspect(e)}") end
  e -> IO.puts("COMPILE-ERR #{inspect(e)}") end
