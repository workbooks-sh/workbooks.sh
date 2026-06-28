# Minimal repro of the rollup root gap: `arr.push(...funcCall().map(fn))` — spreading a CHAINED-method-call
# result directly into push. Proven in the rollup driver: the inline form drops all elements (defs 0), the
# temp-hoisted form works (defs 1). This isolates it to a ~2s compile.
src = """
function g() { return [{modules:'A'}, {modules:'B'}]; }
var defs = [];
defs.push(...g().map(({ modules }) => ({ alias: null, modules })));
console.log('INLINE ' + defs.length);

var t = g().map(({ modules }) => ({ alias: null, modules }));
var defs2 = [];
defs2.push(...t);
console.log('HOISTED ' + defs2.length);

var defs3 = [];
defs3.push(...[10,20,30].map(x => x*2));
console.log('LITERAL ' + defs3.length);
"""
case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} -> case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true) do
    {:ok, out} -> IO.puts(String.replace(out, ~r/\e\[[0-9;]*m/, "") |> String.trim())
    e -> IO.puts("RUN-ERR #{inspect(e)}") end
  e -> IO.puts("COMPILE-ERR #{inspect(e)}") end
