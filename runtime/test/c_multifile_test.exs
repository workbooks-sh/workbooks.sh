defmodule Workbooks.CMultifileTest do
  use ExUnit.Case, async: false

  # wb-yi7q: the in-sandbox C lane (clang.wasm) must build multi-file projects whose sources
  # `#include` local headers. build_dir(dir,"c") now collects the project's .h files, copies them
  # into the guest workdir (structure preserved), and -I's each header dir. @tag :build — needs the
  # clang.wasm artifact + a ~20s in-sandbox compile; run with `--include build`.

  @moduletag :build
  @moduletag timeout: 300_000

  test "build_dir compiles + runs a multi-file C project with a local header" do
    dir = Path.join(System.tmp_dir!(), "cmf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "util.h"), "int square(int);\n")
    File.write!(Path.join(dir, "util.c"), "int square(int x){return x*x;}\n")

    File.write!(Path.join(dir, "index.c"), ~S|#include <stdio.h>
#include "util.h"
int main(void){ printf("ok %d\n", square(7)); return 0; }
|)

    assert {:ok, wasm, _} = Workbooks.PackageManager.build_dir(dir, "c")
    {out, status} = Workbooks.PackageManager.run(wasm, "", [], [], with_status: true)
    assert status == 0
    assert out =~ "ok 49", "multi-file C should compile (square from util.c) + resolve util.h"
    File.rm_rf!(dir)
  end
end
