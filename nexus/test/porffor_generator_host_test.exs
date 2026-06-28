defmodule Nexus.PorfforGeneratorHostTest do
  @moduledoc """
  End-to-end proof of the GENERATOR HOST WIRING: a real Porffor-compiled JS generator body runs on a Washy
  suspension fiber, parking at each `yield` and resuming with the sent value — driven through the three host
  imports (`__porffor_gen_start`/`_yield`/`_resume`). No values cross the wasm boundary: yielded / sent /
  return values ride shared `any` module globals (`__genYielded` / `__genSent` / `__genReturn`) the fiber and
  parent both see, so they round-trip as REAL JS values with full types — numbers, strings, AND objects.

  The guests are hand-written in Porffor's annotated JS against the host-import ABI; the generator source
  transform (vertical 3) will EMIT this same shape. The fiber is started LAZILY (on the first call) and the
  values flow through globals with zero marshaling — the union design that replaced v2.2's mailbox.
  """
  use ExUnit.Case

  defp run!(src) do
    assert {:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(src)
    assert {:ok, out} = Nexus.Compilers.Js.Porffor.run(wasm, transpile: true)

    out
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end

  test "two-way scalar generator: yield out, next(v) in, return value, done detection" do
    # function* g(){ const a = yield 10; const b = yield a + 1; return a + b; }
    src = """
    let __genYielded = 0;
    let __genSent = 0;
    let __genReturn = 0;

    function genBody() {
      __genYielded = 10; __porffor_gen_yield(); const a = __genSent;
      __genYielded = a + 1; __porffor_gen_yield(); const b = __genSent;
      __genReturn = a + b;
    }

    const h = __porffor_gen_start(genBody);       // run to first yield → __genYielded = 10
    console.log(__genYielded);
    __genSent = 5;
    let r = __porffor_gen_resume(h);              // a = 5 → yield 6
    console.log(__genYielded);
    console.log(r);                               // 0 = yielded again
    __genSent = 7;
    r = __porffor_gen_resume(h);                  // b = 7 → return 12, done
    console.log(__genReturn);
    console.log(r);                               // 1 = done
    """

    assert run!(src) == ["10", "6", "0", "12", "1"]
  end

  test "a generator yielding NON-scalar values (string, object, array) round-trips through shared globals" do
    # the v2.2-killer case: values allocated on the fiber must be reachable by the parent (shared malloc +
    # mem-sync across the handoff). function* g(){ yield "hi"; yield {x:7,y:9}; yield [1,2,3]; }
    src = """
    let __genYielded = undefined;
    function genBody() {
      __genYielded = "hi";            __porffor_gen_yield();
      __genYielded = { x: 7, y: 9 };  __porffor_gen_yield();
      __genYielded = [10, 20, 30];    __porffor_gen_yield();
    }
    const h = __porffor_gen_start(genBody);
    console.log(__genYielded);                 // hi
    __porffor_gen_resume(h);
    const o = __genYielded;
    console.log(o.x + o.y);                     // 16
    __porffor_gen_resume(h);
    const a = __genYielded;
    console.log(a[0] + a[2]);                   // 40
    console.log(a.length);                      // 3
    """

    assert run!(src) == ["hi", "16", "40", "3"]
  end

  test "a generator that never yields is done on the first call (return value via __genReturn)" do
    src = """
    let __genReturn = 0;
    function genBody() { __genReturn = 99; }
    const h = __porffor_gen_start(genBody);   // returns 0 = done-on-start
    if (h) { console.log(1); } else { console.log(0); }
    console.log(__genReturn);
    """

    assert run!(src) == ["0", "99"]
  end
end
