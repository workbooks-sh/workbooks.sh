defmodule Workbooks.JsAsyncTest do
  @moduledoc """
  Proves the JS eval host runs ASYNC programs to completion — the keystone unlock for the npm ecosystem
  (HTTP clients, streams, anything I/O). The host bootstrap is `async`: it awaits a thenable eval result
  and StarlingMonkey drives its event loop until it settles; `clocks` is enabled so `setTimeout`/streams
  fire; `JsEngine.run_program`'s capture wrapper runs the bundle in an async IIFE and drains a few macrotask
  turns before returning the buffer.

  Before this, the host returned `String(promise)` ("{}") without awaiting, `.then` never fired, and
  `setTimeout` trapped (clocks disabled). Skips unless the SM eval-host is built.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, JsEngine}

  @root Path.expand(Path.join(__DIR__, "../compilers"))

  setup_all do
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host()) and File.regular?(Path.join(@root, "esbuild/esbuild.wasm"))}
  end

  defp run(name, main, ready?) do
    dir = Path.join(System.tmp_dir!(), "jsasync_#{name}")
    File.rm_rf(dir)
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "package.json"), ~s({"name":"t","version":"1.0.0","type":"module"}))
    File.write!(Path.join([dir, "src", "main.js"]), main)

    case Compilers.esbuild_bundle_dir(dir, "src/main.js", [node_polyfills: true], @root) do
      {:ok, js} ->
        case JsEngine.run_program(js) do
          {:ok, out} -> String.trim(out)
          other -> flunk("run_program: #{inspect(other)}")
        end

      other ->
        flunk("bundle: #{inspect(other) |> String.slice(0, 200)}")
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "async/await, timers, promise chains, and streams drain to captured output", %{ready?: ready?} do
    if not ready? do
      IO.puts("\n[skip] SM eval-host / esbuild not built")
    else
      # async console output is captured (program awaits before logging)
      assert run("await", ~s|(async()=>{await Promise.resolve(); console.log("A"+(40+2))})()|, ready?) == "A42"
      # setTimeout fires (clocks enabled) and its output is drained into the buffer
      assert run("timer", ~s|setTimeout(()=>console.log("timer"+7),0)|, ready?) == "timer7"
      # a promise chain settles before return
      assert run("chain", ~s|Promise.resolve(1).then(v=>v+1).then(v=>console.log("chain"+v))|, ready?) == "chain2"
      # a node stream (async) completes
      assert run("stream", ~s|import {Readable} from "stream"; const r=new Readable({read(){}});let o="";r.on("data",c=>o+=c);r.on("end",()=>console.log("S"+o));r.push("x");r.push("y");r.push(null)|, ready?) == "Sxy"
    end
  end
end
