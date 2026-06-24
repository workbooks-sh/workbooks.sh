defmodule Nexus.WashyCryptoTest do
  @moduledoc """
  The `crypto` concern (wb-5i2i) end to end: a JS `require('crypto')` shim over __host → Nexus.Washy.HostCrypto
  → Erlang :crypto. Proves a whole Node module added as pure Elixir + pure JS, zero shared-file edits. Mirrors
  washy_fs_test.exs. Skips (prints "[skip]") when the qjs-run.wasm probe lacks the generic host bridge.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy.Sandbox

  @qjs "compilers/js/qjs-run.wasm"

  defp run(js), do: Sandbox.run_command({:interp, @qjs, js}, "", fuel: 50_000_000_000, timeout_ms: 60_000)
  defp emit(expr), do: "Javy.IO.writeSync(1,new TextEncoder().encode(String(#{expr})));"

  defp crypto_wasm?, do: File.exists?(@qjs) and match?({:ok, "function"}, run(emit("typeof __host")))

  test "crypto hash/hmac/randomBytes/randomUUID over Erlang :crypto" do
    if crypto_wasm?() do
      # sha256('abc') hex — canonical NIST vector
      assert {:ok, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"} =
               run("var c=require('crypto');" <> emit("c.createHash('sha256').update('abc').digest('hex')"))

      # hmac-sha256 round-trips and is deterministic
      assert {:ok, "true"} =
               run("var c=require('crypto');var a=c.createHmac('sha256','key').update('msg').digest('hex');var b=c.createHmac('sha256','key').update('msg').digest('hex');" <> emit("a===b&&a.length===64"))

      assert {:ok, "16"} =
               run("var c=require('crypto');" <> emit("c.randomBytes(16).length"))

      assert {:ok, "true"} =
               run("var c=require('crypto');" <> emit("/^[0-9a-f-]{36}$/.test(c.randomUUID())"))
    else
      IO.puts("\n[skip] qjs-run.wasm lacks the generic host bridge (rebuild the compilers package)")
    end
  end
end
