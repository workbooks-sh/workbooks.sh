defmodule Nexus.WashyPerfTest do
  @moduledoc """
  The pure-JS `perf_hooks`, `readline`, and the augmented `console` Node core shims (wb-8mdz.1). No host
  calls — registered into the shared CommonJS registry / globals. Runs through Sandbox; SKIPS when the
  local qjs-run.wasm predates these modules (probe `typeof performance.now === 'function'`). The integrator
  rebuilds qjs-run.wasm via `bash compilers/js/build.sh` and runs the full suite.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js), do: Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp perf_wasm?, do: File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof performance.now")))

  test "performance.now() returns a non-negative number" do
    if perf_wasm?() do
      assert {:ok, "number"} = run(emit("typeof performance.now()"))
      assert {:ok, "true"} = run(emit("performance.now() >= 0"))
    else
      IO.puts("\n[skip] qjs-run.wasm lacks perf_hooks (rebuild the compilers package)")
    end
  end

  test "readline emits a 'line' per line and joins on close" do
    if perf_wasm?() do
      js =
        "var rl=require('readline');var src=require('stream').Readable.from(['a\\nb\\n']);" <>
          "var i=rl.createInterface({input:src});var out=[];" <>
          "i.on('line',function(l){out.push(l);});" <>
          "i.on('close',function(){" <> emit("out.join(',')") <> "});"

      assert {:ok, "a,b"} = run(js)
    else
      IO.puts("\n[skip] no readline module")
    end
  end

  test "console.table and group/groupEnd run without throwing" do
    if perf_wasm?() do
      # console.table/log legitimately print to stdout; just assert the calls don't throw and we reach
      # the end marker (the captured stdout contains the table output followed by "OK").
      js =
        "console.table([{x:1}]);console.group();console.log('x');console.groupEnd();" <> emit("'OK'")

      assert {:ok, out} = run(js)
      assert String.ends_with?(out, "OK")
    else
      IO.puts("\n[skip] no console augmentation")
    end
  end
end
