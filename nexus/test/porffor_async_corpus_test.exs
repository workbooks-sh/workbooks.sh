defmodule Nexus.PorfforAsyncCorpusTest do
  @moduledoc """
  G3 — async/Promise event loop, byte-identical microtask ordering to node on the Porffor→Washy ASM lane.

  `test/conformance/async_corpus.js` emits a sequence of markers; the INTERLEAVING (sync vs microtask order,
  await suspension points, combinator results) is what must match node. The golden is native node's output.

  **Currently @tag :skip** — this is the measured target, not yet green, because G3 needs two real pieces that
  do not exist yet (both compiler/runtime-level, not a builtin tweak):

    1. **await suspension.** `__Porffor_promise_await` is a "peek" hack (promise.ts) — it returns the settled
       value synchronously and never yields, so an `async` function runs to completion in the caller's tick
       instead of suspending at `await` and resuming via a microtask. Real await needs async functions lowered
       to resumable state machines (coroutines, via the generator machinery), so `await x` yields to the caller
       and a `.then` on `x` resumes the function. This is why the ASM output runs `after-await1|after-await2`
       BEFORE `sync-after-async` (node runs `sync-after-async|sync-end` first, then resumes after the await).

    2. **combinator per-call state.** Promise.all/allSettled/any/race share module-level globals (builtins can
       NOT capture enclosing locals — closure-conversion only runs on user code), so sequential calls in one
       tick stomp each other → `all:`/`race:` vanish and `settled:` is `undefined`. The fix carries per-call
       state (result array, index, remaining, resolve fn) through the promise REACTION machinery (extend the
       reaction tuple with a context slot), since a `.then` handler in a builtin can't close over them.

  Node golden interleaving (the target):
      sync-start|sync-mid|async-enter|sync-after-async|sync-end|p1-then|after-await1|p2-then|p-catch:e|
      p1-then2|after-await2|p-finally|all:1,2|race:fast|settled:fulfilled,rejected2

  When both pieces land, drop `@tag :skip` and this becomes a hard byte-identical gate (and a regression guard
  for Rollup's async bundle path, which G4 depends on).
  """
  use ExUnit.Case, async: false

  alias Nexus.Compilers.Js.Porffor

  @conf Path.join(__DIR__, "conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  @tag :skip
  test "async/Promise microtask ordering is byte-identical to node on the ASM lane" do
    corpus = File.read!(Path.join(@conf, "async_corpus.js"))
    golden = File.read!(Path.join(@conf, "async_corpus.golden.txt")) |> String.trim_trailing("\n")

    src = File.read!(@prelude) <> "\n" <> corpus
    {:ok, r} = Nexus.Porffor.Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
    assert r.completed, "async corpus run did not complete: #{inspect(r.trap || r.error)}"
    assert String.trim_trailing(r.output, "\n") == golden
  end
end
