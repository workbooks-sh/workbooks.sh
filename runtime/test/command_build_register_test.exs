defmodule Workbooks.CommandBuildRegisterTest do
  use ExUnit.Case, async: false

  # The Lane-B join: build a multi-file C tool in-sandbox (clang.wasm) and register it as a live
  # command. @tag :build — needs the clang.wasm artifact + an in-sandbox compile; run with `--include build`.

  @moduletag :build
  @moduletag timeout: 300_000

  alias Workbooks.CommandRegistry

  test "register_built_dir builds a multi-file C tool from a local dir + registers it as a live command" do
    dir = Path.join(System.tmp_dir!(), "cbr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "util.h"), "int dbl(int);\n")
    File.write!(Path.join(dir, "util.c"), "int dbl(int x){ return x + x; }\n")

    File.write!(Path.join(dir, "index.c"), ~S|#include <stdio.h>
#include <stdlib.h>
#include "util.h"
int main(int argc, char **argv){ int n = argc > 1 ? atoi(argv[1]) : 0; printf("%d\n", dbl(n)); return 0; }
|)

    assert {:ok, _addressed} = CommandRegistry.register_built_dir("wbdbl", dir, "c")
    assert "wbdbl" in CommandRegistry.list()
    assert {:ok, out} = CommandRegistry.run("wbdbl", "", ["21"])
    assert String.trim(out) == "42"
    File.rm_rf!(dir)
  end
end
