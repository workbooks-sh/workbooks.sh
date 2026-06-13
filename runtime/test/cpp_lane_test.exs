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
  test "compile_cpp — exceptions are honestly gated (try/throw fails to link until an EH sysroot is staged)" do
    src = Path.join(System.tmp_dir!(), "cppeh_#{System.unique_integer([:positive])}.cpp")
    File.write!(src, ~S"""
    #include <stdexcept>
    int main(){ try { throw std::runtime_error("x"); } catch(...) { return 0; } return 1; }
    """)

    on_exit(fn -> File.rm(src) end)
    # default no-exceptions build: throwing code must NOT silently "work" — it fails at link (honest boundary).
    assert {:error, _} = Compilers.compile_cpp(src, exceptions: true)
  end
end
