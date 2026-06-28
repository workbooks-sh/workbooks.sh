defmodule Nexus.PorfforGeneratorHostTest do
  @moduledoc """
  End-to-end proof of the GENERATOR HOST WIRING (v2.2): a real Porffor-compiled JS generator body runs on a
  Washy suspension fiber, parking at each `yield` and resuming with the sent value — driven entirely through
  the three host imports (`__porffor_gen_spawn`/`_yield`/`_resume`) and the 12-byte `any` mailbox ABI.

  The guest is hand-written in Porffor's annotated-JS (`Porffor.wasm` dialect) so it exercises the host side
  WITHOUT the generator source transform (that's vertical 3 — it will EMIT these same import calls). Scalar
  (number) yields only: a generator that allocates across a `yield` needs shared malloc globals (a v3
  follow-up); the machinery itself is proven here.
  """
  use ExUnit.Case

  # ── a two-way scalar generator + driver, written directly against the gen host imports ────────────────
  #   function* g(){ const a = yield 10; const b = yield a + 1; }
  #   const it = g(); it.next() -> 10 ; it.next(5) -> 6 ; it.next(7) -> done
  # Mailbox: f64 value @ mbx+0, i32 type @ mbx+8 (1 = number), i32 done @ mbx+12 (0 yielded / 1 done).
  @guest """
  const __mbx = Porffor.malloc();

  const __genYield = (v) => {
    Porffor.wasm.f64.store(__mbx, v, 0, 0);
    Porffor.wasm.i32.store(__mbx + 8, 1, 0, 0);
    __porffor_gen_yield(__mbx);
    return Porffor.wasm.f64.load(__mbx, 0, 0);
  };

  function genBody() {
    const a = __genYield(10);
    const b = __genYield(a + 1);
  }

  const __sendNum = (v) => {
    Porffor.wasm.f64.store(__mbx, v, 0, 0);
    Porffor.wasm.i32.store(__mbx + 8, 1, 0, 0);
  };

  const h = __porffor_gen_spawn(genBody);

  // it.next() -> first yielded value (10), not done
  __porffor_gen_resume(h, __mbx);
  console.log(Porffor.wasm.f64.load(__mbx, 0, 0));
  console.log(Porffor.wasm.i32.load(__mbx + 12, 0, 0));

  // it.next(5) -> a=5, yields a+1=6, not done
  __sendNum(5);
  __porffor_gen_resume(h, __mbx);
  console.log(Porffor.wasm.f64.load(__mbx, 0, 0));
  console.log(Porffor.wasm.i32.load(__mbx + 12, 0, 0));

  // it.next(7) -> b=7, body returns -> done
  __sendNum(7);
  __porffor_gen_resume(h, __mbx);
  console.log(Porffor.wasm.i32.load(__mbx + 12, 0, 0));
  """

  test "a real Porffor generator yields, suspends, and resumes with the sent value through the fiber" do
    assert {:ok, wasm} = Nexus.Compilers.Js.Porffor.compile(@guest)
    assert {:ok, out} = Nexus.Compilers.Js.Porffor.run(wasm, transpile: true)

    nums =
      out
      # strip ANSI color codes console.log wraps numbers in
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(fn s -> s |> String.trim() |> Float.parse() |> elem(0) end)

    assert nums == [
             # it.next()  → {value: 10, done: false}
             10.0,
             0.0,
             # it.next(5) → a=5, {value: 6, done: false}
             6.0,
             0.0,
             # it.next(7) → b=7, body returns → done
             1.0
           ]
  end
end
