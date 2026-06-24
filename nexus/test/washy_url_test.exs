defmodule Nexus.WashyUrlTest do
  @moduledoc """
  The pure-JS `url` + `string_decoder` Node core modules (wb-ihge, Wave-1). No host calls — these are
  registered into the shared CommonJS registry and the WHATWG globals (URL/URLSearchParams). Runs through
  Sandbox; SKIPS when qjs-run.wasm predates these modules (probe `typeof URL === 'function'`).
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js), do: Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp url_wasm?, do: File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof URL")))

  test "WHATWG URL parses components" do
    if url_wasm?() do
      assert {:ok, "ex.com|8080|/a/b|?x=1|#h|https:|u|p"} =
               run(
                 "var u=new URL('https://u:p@ex.com:8080/a/b?x=1#h');" <>
                   emit("[u.hostname,u.port,u.pathname,u.search,u.hash,u.protocol,u.username,u.password].join('|')")
               )

      assert {:ok, "https://ex.com:8080"} =
               run("var u=new URL('https://u:p@ex.com:8080/a/b?x=1#h');" <> emit("u.origin"))

      assert {:ok, "ex.com:8080"} =
               run("var u=new URL('https://ex.com:8080/a');" <> emit("u.host"))
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the url module (rebuild the compilers package)")
    end
  end

  test "URLSearchParams get/append/getAll" do
    if url_wasm?() do
      assert {:ok, "2"} =
               run("var p=new URLSearchParams('a=1&b=2');" <> emit("p.get('b')"))

      assert {:ok, "1,3"} =
               run("var p=new URLSearchParams('a=1&b=2');p.append('a','3');" <> emit("p.getAll('a').join(',')"))

      assert {:ok, "true"} =
               run(
                 "var u=new URL('https://ex.com/?x=1');u.searchParams.append('y','2');" <>
                   emit("u.href==='https://ex.com/?x=1&y=2'")
               )
    else
      IO.puts("\n[skip] no url module")
    end
  end

  test "legacy url.parse/format/resolve" do
    if url_wasm?() do
      assert {:ok, "ex.com|/a|?x=1|x=1"} =
               run(
                 "var url=require('url');var o=url.parse('http://ex.com/a?x=1',true);" <>
                   emit("[o.hostname,o.pathname,o.search,JSON.stringify(o.query).replace(/[{}\\\"]/g,'').replace(':','=')].join('|')")
               )

      assert {:ok, "https://ex.com/c"} =
               run("var url=require('url');" <> emit("url.resolve('https://ex.com/a/b','/c')"))
    else
      IO.puts("\n[skip] no url module")
    end
  end

  test "string_decoder reassembles split multibyte utf8" do
    if url_wasm?() do
      # '€' = [0xE2,0x82,0xAC] split across two write() calls
      assert {:ok, "€"} =
               run(
                 "var SD=require('string_decoder').StringDecoder;var d=new SD('utf8');" <>
                   "var a=d.write(Buffer.from([0xE2,0x82]));var b=d.write(Buffer.from([0xAC]));" <>
                   emit("a+b")
               )

      assert {:ok, "ab"} =
               run(
                 "var SD=require('string_decoder').StringDecoder;var d=new SD('utf8');" <>
                   emit("d.write(Buffer.from('ab','utf8'))")
               )
    else
      IO.puts("\n[skip] no string_decoder module")
    end
  end
end
