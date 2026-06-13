defmodule Workbooks.CppLaneTest do
  @moduledoc """
  Proves the in-sandbox C++ compile lane (Compilers.compile_cpp): full STL + RTTI + virtual dispatch + new/delete
  via the vendored libc++/libc++abi, clang.wasm, zero native toolchain. This is the lever for the large C++
  ecosystem (the no-exceptions subset today; full exceptions once an EH sysroot is staged). Pairs with the C
  lane (already live) — together they cover compile-from-source for the C/C++ world.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @tag :build
  @tag timeout: 300_000
  test "compile_cpp — full STL + RTTI + virtual dispatch run in-sandbox (no-exceptions C++)" do
    src = Path.join(System.tmp_dir!(), "cpplane_#{System.unique_integer([:positive])}.cpp")

    File.write!(src, ~S"""
    #include <cstdio>
    #include <vector>
    #include <map>
    #include <string>
    #include <algorithm>
    struct Shape { virtual ~Shape(){} virtual int area() const { return 0; } };
    struct Square : Shape { int s; Square(int s):s(s){} int area() const override { return s*s; } };
    int main(){
      std::vector<int> v{5,3,8,1,9,2}; std::sort(v.begin(), v.end());
      int sum=0; for(int x:v) sum+=x;
      std::map<std::string,int> m; m["x"]=10; m["y"]=20; m["z"]=30;
      Shape* sh = new Square(7);
      Square* sq = dynamic_cast<Square*>(sh);          // RTTI pointer cast
      printf("SUM=%d MIN=%d MAX=%d MAP=%d AREA=%d ISSQUARE=%d\n",
             sum, v.front(), v.back(), (int)m.size(), sh->area(), sq!=nullptr);
      delete sh; return 0;
    }
    """)

    on_exit(fn -> File.rm(src) end)

    assert {:ok, wasm, _} = Compilers.compile_cpp(src)
    on_exit(fn -> File.rm(wasm) end)

    out = PackageManager.run(wasm, "", [])
    out = if is_tuple(out), do: elem(out, 0), else: out
    assert out =~ "SUM=28"
    assert out =~ "MIN=1" and out =~ "MAX=9"
    assert out =~ "MAP=3"
    assert out =~ "AREA=49"
    assert out =~ "ISSQUARE=1"
  end

  @tag :build
  @tag timeout: 300_000
  test "compile_cpp(exceptions: true) — try/throw/catch + RAII destructor-during-unwind run in-sandbox" do
    # Skip-guard: the EH archives are GITIGNORED build artifacts staged by compilers/clang/build.sh — mirror the
    # threads test's File.dir? guard so a tree that hasn't built them doesn't spuriously fail.
    ehdir =
      Path.expand(
        Path.join([Compilers.default_root(), "clang", "clang-root", "sysroot", "lib", "wasm32-wasip1"])
      )

    if not File.regular?(Path.join(ehdir, "libc++abi-eh.a")) do
      IO.puts("\n[skip] C++ EH archives not staged (run compilers/clang/build.sh) — skipping exceptions test")
    else
      src = Path.join(System.tmp_dir!(), "cppeh_#{System.unique_integer([:positive])}.cpp")

      File.write!(src, ~S"""
      #include <cstdio>
      #include <stdexcept>
      // RAII guard whose destructor MUST fire during stack unwinding as the throw propagates.
      struct Guard { const char* n; ~Guard(){ printf("DTOR=%s\n", n); } };
      int main(){
        try {
          Guard g{"unwound"};
          throw std::runtime_error("boom");
        } catch (const std::exception& e) {
          printf("CAUGHT=%s\n", e.what());
        }
        printf("AFTER=ok\n");
        return 0;
      }
      """)

      on_exit(fn -> File.rm(src) end)

      assert {:ok, wasm, _} = Compilers.compile_cpp(src, exceptions: true)
      on_exit(fn -> File.rm(wasm) end)

      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      # RAII destructor ran during unwind, BEFORE the catch handler printed.
      assert out =~ "DTOR=unwound"
      assert out =~ "CAUGHT=boom"
      assert out =~ "AFTER=ok"
      # ordering: destructor (unwind) precedes the catch, which precedes resumption.
      assert :binary.match(out, "DTOR=unwound") < :binary.match(out, "CAUGHT=boom")
      assert :binary.match(out, "CAUGHT=boom") < :binary.match(out, "AFTER=ok")
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "build_c_dir — C++ exceptions ACROSS FILES (the multi-file lane real C++ tools use)" do
    # The dir-build lane (binaryen/DuckDB-class) must also link the EH runtime — not just single-file compile_cpp.
    if not Compilers.cpp_eh_staged?() do
      IO.puts("\n[skip] C++ EH archives not staged (run compilers/clang/build.sh) — skipping dir-build exceptions test")
    else
      d = Path.join(System.tmp_dir!(), "cppdir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(d)
      on_exit(fn -> File.rm_rf(d) end)

      File.write!(Path.join(d, "lib.h"), "void risky(int);\n")

      File.write!(Path.join(d, "lib.cpp"), ~S"""
      #include <stdexcept>
      #include "lib.h"
      void risky(int x){ if (x < 0) throw std::out_of_range("neg"); }
      """)

      File.write!(Path.join(d, "main.cpp"), ~S"""
      #include <cstdio>
      #include <stdexcept>
      #include "lib.h"
      struct Guard { ~Guard(){ printf("DTOR\n"); } };
      int main(){
        try { Guard g; risky(-5); printf("UNREACHABLE\n"); }      // throw originates in a DIFFERENT translation unit
        catch (const std::out_of_range& e) { printf("CAUGHT=%s\n", e.what()); }
        printf("AFTER\n");
        return 0;
      }
      """)

      assert {:ok, wasm, _} = PackageManager.build_c_dir(d, [])
      on_exit(fn -> File.rm(wasm) end)

      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "CAUGHT=neg"          # cross-file throw caught
      assert out =~ "DTOR"                # RAII destructor ran during unwind
      assert out =~ "AFTER"
      refute out =~ "UNREACHABLE"
    end
  end
end
