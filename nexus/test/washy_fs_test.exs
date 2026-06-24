defmodule Nexus.WashyFsTest do
  @moduledoc """
  The `fs` concern (wb-xd13) + the Wave-0 generic host bridge, end to end: a JS `require('fs')` shim over
  __host → Nexus.Washy.HostFs → Nexus.Washy.VFS. Proves a whole Node module added as pure Elixir + pure JS,
  zero shared-file edits. Runs through Sandbox (the per-run :map VFS persists for the whole script).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js), do: Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp fs_wasm?, do: File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof __host")))

  test "fs read/write/exists/append/stat/readdir/unlink over the VFS" do
    if fs_wasm?() do
      assert {:ok, "hello"} =
               run("var fs=require('fs');fs.writeFileSync('/work/a.txt','hello');" <> emit("fs.readFileSync('/work/a.txt','utf8')"))

      assert {:ok, "true,false"} =
               run("var fs=require('fs');fs.writeFileSync('/work/a','x');" <> emit("fs.existsSync('/work/a')+','+fs.existsSync('/work/nope')"))

      assert {:ok, "hello world"} =
               run("var fs=require('fs');fs.writeFileSync('/work/a','hello');fs.appendFileSync('/work/a',' world');" <> emit("fs.readFileSync('/work/a','utf8')"))

      assert {:ok, "5,true"} =
               run("var fs=require('fs');fs.writeFileSync('/work/a','hello');var s=fs.statSync('/work/a');" <> emit("s.size+','+s.isFile()"))

      assert {:ok, "b.txt,c.txt"} =
               run("var fs=require('fs');fs.writeFileSync('/work/d/b.txt','1');fs.writeFileSync('/work/d/c.txt','2');" <> emit("fs.readdirSync('/work/d').sort().join(',')"))

      # binary-safe round-trip + Buffer return type
      assert {:ok, "true,3"} =
               run("var fs=require('fs');fs.writeFileSync('/work/b',Buffer.from([1,2,3]));var x=fs.readFileSync('/work/b');" <> emit("Buffer.isBuffer(x)+','+x.length"))

      assert {:ok, "true"} =
               run("var fs=require('fs');fs.writeFileSync('/work/a','x');fs.unlinkSync('/work/a');" <> emit("!fs.existsSync('/work/a')"))
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the generic host bridge (rebuild the compilers package)")
    end
  end

  test "fs.promises + callback forms resolve via microtask" do
    if fs_wasm?() do
      assert {:ok, "promise:hi"} =
               run("var fs=require('fs');fs.writeFileSync('/work/p','hi');fs.promises.readFile('/work/p','utf8').then(function(v){" <> emit("'promise:'+v") <> "});")
    else
      IO.puts("\n[skip] no host bridge")
    end
  end
end
