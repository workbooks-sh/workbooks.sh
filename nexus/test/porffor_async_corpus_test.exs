defmodule Nexus.PorfforAsyncCorpusTest do
  @moduledoc """
  G3 — async/Promise event loop, byte-identical microtask ordering to node on the Porffor→Washy ASM lane.

  `test/conformance/async_corpus.js` emits a sequence of markers; the INTERLEAVING (sync vs microtask order,
  await suspension points, combinator results) is what must match node. The golden is native node's output.

  **Currently @tag :skip** — one of the two G3 pieces remains:

    1. **await suspension (REMAINING).** `__Porffor_promise_await` is a "peek" hack (promise.ts) — it returns
       the settled value synchronously and never yields, so an `async` function runs to completion in the
       caller's tick instead of suspending at `await` and resuming via a microtask. Real await needs async
       functions lowered to resumable state machines (coroutines, via the generator machinery), so `await x`
       yields to the caller and a `.then` on `x` resumes the function. This is the only remaining divergence:
       the ASM output runs `after-await1|after-await2` BEFORE `sync-after-async` (node runs `sync-after-async|
       sync-end` first, then resumes after the await).

    2. **combinator per-call state (DONE).** Promise.all/allSettled/any/race used to share module globals
       (builtins can't capture locals — closure-conversion is user-code-only), so sequential calls in one tick
       stomped each other (`all:`/`race:` vanished, `settled:` was `undefined`). Fixed by carrying per-call
       state [out, remaining, outPromise, settledFlag, kind] in a per-call array threaded to each input
       promise's reaction via a 4th reaction slot, read by a kind-based dispatcher through a module-global
       `__combineCtx` set in runJobs immediately before each (synchronous, non-reentrant) handler call — since
       a builtin handler can't capture, can't take a fn as a call arg, and can't be called with a 2nd arg.
       Now byte-identical: `all:1,2,3|race:fast|settled:fulfilled,rejected2|any:b`.

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
