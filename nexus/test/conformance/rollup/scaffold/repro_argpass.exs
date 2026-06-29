# Confirmed: the new Chunk 10th arg (this.includedNamespaces, a defined Set) arrives undefined at the
# constructor — lost in transit. Generic literal args (repro_arity) all arrived, so it's the real call's
# SHAPE: 15 args mixing member-exprs + a NESTED member (this.graph.modulesById at pos 6) + locals, called
# from inside a method. Repro that exact shape; P10 = D means no bug, U = reproduced.
src = """
var C = class {
  constructor(p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15) {
    this.all = [p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15].map(function(x){return x===undefined?'U':'D'}).join('');
  }
};
var Caller = class {
  constructor() {
    this.io={}; this.oo={}; this.uo={}; this.pd={}; this.gr={mb:new Map()};
    this.fcbm=new Map(); this.ns=new Set(); this.ns.add(1);
  }
  make(modules, cbm, ecbm, alias, ghp, bundle, ib, sn) {
    return new C(modules, this.io, this.oo, this.uo, this.pd, this.gr.mb, cbm, ecbm, this.fcbm, this.ns, alias, ghp, bundle, ib, sn);
  }
};
var caller = new Caller();
console.log('CALLER_NS ' + (caller.ns===undefined?'U':'D'));
var c = caller.make([0], new Map(), new Map(), 'al', function(){}, {}, '/', {});
console.log('ALL ' + c.all);
"""
case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} -> case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true) do
    {:ok, out} -> IO.puts(String.replace(out, ~r/\e\[[0-9;]*m/, "") |> String.trim())
    e -> IO.puts("RUN-ERR #{inspect(e)}") end
  e -> IO.puts("COMPILE-ERR #{inspect(e)}") end
