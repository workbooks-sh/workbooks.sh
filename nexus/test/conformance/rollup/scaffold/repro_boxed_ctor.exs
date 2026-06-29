# The real bundle is an IIFE, so Chunk is IIFE-LOCAL and boxed when `new`'d from a method → routes through
# __cnew → Reflect.construct → Porffor.call, which spreads the args array via the 8-SLOT expansion
# (codegen.js:2653 `for i<8`). My earlier repros used #main top-level classes = native new (no spread) =
# 15 args. This repro forces the IIFE-local boxed path. Expect DDDDDDDD U... (cutoff at 8) = the bug.
src = """
(function(){
  var Inner = class {
    constructor(p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15) {
      this.r = [p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15].map(function(x){return x===undefined?'U':'D'}).join('');
    }
  };
  var Caller = class { make() { return new Inner(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15); } };
  var c = new Caller().make();
  console.log('IIFE_BOXED ' + c.r);
})();
"""
case Nexus.Compilers.Js.Porffor.compile(src) do
  {:ok, wasm} -> case Nexus.Compilers.Js.Porffor.run(wasm, transpile: true) do
    {:ok, out} -> IO.puts(String.replace(out, ~r/\e\[[0-9;]*m/, "") |> String.trim())
    e -> IO.puts("RUN-ERR #{inspect(e)}") end
  e -> IO.puts("COMPILE-ERR #{inspect(e)}") end
