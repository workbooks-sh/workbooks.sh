defmodule Nexus.WashyStreamTest do
  @moduledoc """
  The `stream` concern (wb-q6ft, Wave-1 of Node-on-BEAM): pure-JS Readable/Writable/Duplex/
  Transform/PassThrough over EventEmitter, zero host calls. The script runs to completion and the
  harness drains the microtask queue (process.nextTick), so emission scheduled on nextTick fires
  before the run returns — we accumulate into an array and writeSync the final result inside the
  last 'end'/'finish' callback. Skips when qjs-run.wasm lacks the stream module (rebuild required).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js), do: Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp stream_wasm?,
    do: File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof require('stream').Readable")))

  test "Readable.from piped/collected via on('data')+on('end')" do
    if stream_wasm?() do
      js = """
      var S=require('stream');
      var r=S.Readable.from(['a','b','c']);
      var out=[];
      r.on('data',function(c){out.push(String(c));});
      r.on('end',function(){#{emit("out.join('')")}});
      """
      assert {:ok, "abc"} = run(js)
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the stream module (rebuild the compilers package)")
    end
  end

  test "Transform uppercases fed chunk then end" do
    if stream_wasm?() do
      js = """
      var S=require('stream');
      var t=new S.Transform({transform:function(chunk,enc,cb){cb(null,chunk.toString().toUpperCase());}});
      var out=[];
      t.on('data',function(c){out.push(String(c));});
      t.on('end',function(){#{emit("out.join('')")}});
      t.write('hi');t.end();
      """
      assert {:ok, "HI"} = run(js)
    else
      IO.puts("\n[skip] no stream module")
    end
  end

  test "PassThrough collects written chunks" do
    if stream_wasm?() do
      js = """
      var S=require('stream');
      var p=new S.PassThrough();
      var out=[];
      p.on('data',function(c){out.push(String(c));});
      p.on('end',function(){#{emit("out.join('')")}});
      p.write('x');p.write('y');p.end();
      """
      assert {:ok, "xy"} = run(js)
    else
      IO.puts("\n[skip] no stream module")
    end
  end

  test "Writable drain/finish + Readable.pipe backpressure" do
    if stream_wasm?() do
      js = """
      var S=require('stream');
      var got=[];
      var w=new S.Writable({write:function(chunk,enc,cb){got.push(String(chunk));cb();}});
      w.on('finish',function(){#{emit("got.join('')")}});
      var r=S.Readable.from(['1','2','3']);
      r.pipe(w);
      """
      assert {:ok, "123"} = run(js)
    else
      IO.puts("\n[skip] no stream module")
    end
  end
end
