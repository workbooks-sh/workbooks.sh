# Arity is ruled out — the Bundle's `this.includedNamespaces` (a Set) is itself undefined at the new Chunk
# call. Test the two cheap mechanisms: (1) does `this.ns = new Set()` in a constructor survive a later read?
# (2) does a Set passed through a constructor param survive? Self-validating U/D.
src = """
var S = class { constructor() { this.ns = new Set(); } get() { return this.ns; } };
var s = new S();
console.log('CTOR_SET ' + (s.ns===undefined?'U':'D') + ' viaget=' + (s.get()===undefined?'U':'D') + ' hasfn=' + (s.ns && typeof s.ns.has));

var theSet = new Set();
theSet.add(7);
var C = class { constructor(p1,p2,p3,p4,p5,p6,p7,p8,p9,ns) { this.ns = ns; } };
var c = new C(1,2,3,4,5,6,7,8,9,theSet);
console.log('PARAM_SET ' + (c.ns===undefined?'U':'D') + ' has7=' + (c.ns && c.ns.has(7)));

// Set assigned to an object property then read through a method (closure_convert path)
var o = {}; o.ns = new Set(); o.ns.add(3);
console.log('OBJ_SET ' + (o.ns===undefined?'U':'D') + ' has3=' + (o.ns && o.ns.has(3)));
"""
case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} -> case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true) do
    {:ok, out} -> IO.puts(String.replace(out, ~r/\e\[[0-9;]*m/, "") |> String.trim())
    e -> IO.puts("RUN-ERR #{inspect(e)}") end
  e -> IO.puts("COMPILE-ERR #{inspect(e)}") end
