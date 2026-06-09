defmodule Workbooks.InlineLangsTest do
  @moduledoc """
  wb-pkh.4 — validate inline self-authoring (build_and_register_inline) across the
  language lanes, not just JS. Each test writes a reverse-stdin command in a lane,
  builds it ENTIRELY in the wasm sandbox, registers it, and runs it.

  Lane status (verified 2026-06-08):
    * js   ✅ (also covered in command_registry_test)
    * c    ✅
    * go   ✅ (yaegi)
    * rust ✅ (mrustc full-std; slow, cached)
    * zig  ❌ stdin/stdout filters fail at link (_start undefined) — see wb-pkh.10.
            zig compute/debug-print works, but the stdio command shape does not.
  """
  use ExUnit.Case, async: false

  alias Workbooks.CommandRegistry, as: CR

  defp uniq(p), do: "#{p}_#{System.unique_integer([:positive])}"

  defp build_run(lang, src, input) do
    name = uniq("il_#{lang}")
    {:ok, _} = CR.build_and_register_inline(name, lang, src)
    CR.run(name, input)
  end

  @tag :build
  test "C lane self-authors a stdin→stdout command" do
    src = ~S|
    #include <unistd.h>
    int main(){ static char b[65536]; int n=0,r; while((r=read(0,b+n,sizeof(b)-n))>0) n+=r; for(int i=n-1;i>=0;i--) write(1,&b[i],1); return 0; }
    |
    assert {:ok, "cba"} = build_run("c", src, "abc")
  end

  @tag :build
  test "Go lane self-authors a stdin→stdout command (yaegi)" do
    src = ~S|
    package main
    import ("io"; "os")
    func main(){ b, _ := io.ReadAll(os.Stdin); for i := len(b)-1; i >= 0; i-- { os.Stdout.Write(b[i:i+1]) } }
    |
    assert {:ok, "cba"} = build_run("go", src, "abc")
  end

  @tag :build
  @tag timeout: 600_000
  test "Rust lane self-authors a stdin→stdout command (mrustc full-std; slow)" do
    src = ~S|
    use std::io::{Read, Write};
    fn main() {
        let mut b = Vec::new();
        std::io::stdin().read_to_end(&mut b).unwrap();
        b.reverse();
        std::io::stdout().write_all(&b).unwrap();
    }
    |
    assert {:ok, "cba"} = build_run("rust", src, "abc")
  end

  @tag :build
  test "Zig stdio command is a KNOWN GAP — but now fails with a MEANINGFUL error (wb-pkh.10)" do
    # Root cause (diagnosed wb-pkh.10): the bundled zig std lacks `std.io` — its
    # std.zig has no `io` member (a minimal std; std.debug works, std.io doesn't).
    # So it's a provisioning/bundle-completeness issue, NOT a recipe bug.
    # Previously this slipped through as an empty out.c → misleading "_start
    # undefined" link error. Now the empty-output guard surfaces the real compile
    # failure. When the zig std is re-provisioned with std.io, flip to {:ok,"cba"}.
    src = ~S|
    const std = @import("std");
    pub fn main() void {
        var buf: [65536]u8 = undefined;
        const n = std.io.getStdIn().reader().readAll(&buf) catch 0;
        const w = std.io.getStdOut().writer();
        var i: usize = n;
        while (i > 0) { i -= 1; _ = w.writeByte(buf[i]) catch {}; }
    }
    |
    name = uniq("il_zig")
    # A COMPILE failure (the real zig1 error), not the old misleading link failure.
    assert {:error, {:build_failed, {:compile_failed, _}}} =
             CR.build_and_register_inline(name, "zig", src)
  end
end
