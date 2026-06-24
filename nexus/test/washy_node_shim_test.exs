defmodule Nexus.WashyNodeShimTest do
  @moduledoc """
  The **Node-core shim layer**: a CommonJS `require` over the 80/20 pure-JS core modules
  (`process`, `events`, `util`, `path`, `buffer`, `os`, `assert`, `querystring`) baked into the
  qjs-run harness prelude. This is the unlock that turns "runs pure JS" into "runs npm packages that
  expect Node stdlib" — without an event loop / host I/O (those modules come later, OTP-backed).

  Skips gracefully when the local qjs-run.wasm predates the Node prelude (it's gitignored — part of
  the separately-published compilers package), detected by probing `typeof require`.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js) do
    Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  end

  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp node_wasm? do
    File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof require")))
  end

  test "the Node-core shim layer is present and correct" do
    if node_wasm?() do
      # events: EventEmitter on/emit accumulates
      assert {:ok, "7"} =
               run("var EE=require('events');var e=new EE();var g=0;e.on('x',v=>g+=v);e.emit('x',5);e.emit('x',2);" <> emit("g"))

      # path: join collapses '..', basename strips ext, extname is the last suffix
      assert {:ok, "/a/c|y|.gz"} =
               run(emit("require('path').join('/a/b','../c')+'|'+require('path').basename('/x/y.js','.js')+'|'+require('path').extname('f.tar.gz')"))

      # util.format with %s/%d/%j
      assert {:ok, "hi-3-{\"a\":1}"} = run(emit("require('util').format('%s-%d-%j','hi',3,{a:1})"))

      # buffer: hex round-trip, base64 decode, concat
      assert {:ok, "68656c6c6f|hi|abcd"} =
               run(emit("(function(){var B=require('buffer').Buffer;return B.from('hello').toString('hex')+'|'+B.from('aGk=','base64').toString()+'|'+B.concat([B.from('ab'),B.from('cd')]).toString();})()"))

      # os, querystring, process globals
      assert {:ok, "linux|10"} = run(emit("require('os').platform()+'|'+require('os').EOL.charCodeAt(0)"))
      assert {:ok, "a=1&b=x%20y"} = run(emit("require('querystring').stringify({a:1,b:'x y'})"))
      assert {:ok, "linux|function"} = run(emit("process.platform+'|'+(typeof process.nextTick)"))

      # assert throws on inequality; Buffer is a global (Node-style)
      assert {:ok, "true|true"} =
               run("var a=false;try{require('assert').equal(1,2);}catch(_){a=true;}" <> emit("a+'|'+(typeof Buffer==='function')"))
    else
      IO.puts("\n[skip] qjs-run.wasm predates the Node-core shim (rebuild the compilers package)")
    end
  end
end
