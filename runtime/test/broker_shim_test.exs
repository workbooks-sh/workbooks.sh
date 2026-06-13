defmodule Workbooks.BrokerShimTest do
  @moduledoc """
  Proves the ergonomic shim: a C tool `#include "wb_broker.h"` and calls wb_http_get()/wb_exec() to get
  SSRF-mediated brokered networking + brokered command dispatch, built + run through BuildBroker's :broker mode
  (no per-tool host code, zero native toolchain). The host does the privileged op behind the file protocol; the
  guest stays sandboxed and only ever reads/writes /b.
  """
  use ExUnit.Case, async: false
  alias Workbooks.BuildBroker

  @tool ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "wb_broker.h"
  int main(void){
    static unsigned char buf[65536];
    int a = wb_http_get("http://example.com/", buf, sizeof(buf));
    printf("PUBLIC %d\n", a >= 0 ? 1 : 0);
    int b = wb_http_get("http://169.254.169.254/latest/meta-data/", buf, sizeof(buf));
    printf("INTERNAL %d\n", b >= 0 ? 1 : 0);
    int e = wb_exec("jq", "[\".\"]", "", buf, sizeof(buf));
    printf("EXEC %d\n", e >= 0 ? 1 : 0);
    return 0;
  }
  """

  @tag :build
  @tag :netdeps
  @tag timeout: 600_000
  test "C shim — brokered HTTP (public OK, internal DENIED) + brokered exec when granted" do
    assert {:ok, out} =
             BuildBroker.build_and_run(:c, @tool, "",
               allow: true,
               broker: true,
               net_allow: ["example.com"],
               exec_allow: true,
               commands: ["jq"]
             )

    assert out =~ "PUBLIC 1", out
    assert out =~ "INTERNAL 0", out
    assert out =~ "EXEC 1", out
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 600_000
  test "C shim — exec is DEFAULT-DENY (wb_exec refused unless :exec_allow granted)" do
    assert {:ok, out} = BuildBroker.build_and_run(:c, @tool, "", allow: true, broker: true)

    # net still works (SSRF floor, no allow-list) but exec is off by default -> wb_exec returns -1
    assert out =~ "PUBLIC 1", out
    assert out =~ "EXEC 0", out
  end

  @orchestrator ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "wb_broker.h"
  int main(void){
    static unsigned char out[4096];
    int n = wb_exec("wb-upper", "[]", "hello world", out, sizeof(out));
    if(n < 0){ printf("DENIED\n"); return 1; }
    out[n]=0;
    printf("RESULT[%s]\n", out);
    return 0;
  }
  """

  @tag :build
  @tag timeout: 600_000
  test "ORCHESTRATION — a C build-driver pipes stdin into a brokered Python tool and reads its output" do
    # cross-language brokered orchestration: a compiled C tool drives a registered :pynet command, with input
    # flowing through (wb_exec stdin -> base64 -> host -> CPython stdin -> transform -> back). The Make/Ninja/
    # build-driver class realized: a native-style orchestrator dispatching brokered tools, all sandboxed.
    upper = ~S"""
    import sys
    sys.stdout.write(sys.stdin.read().upper())
    """

    :ok = Workbooks.CommandRegistry.register_pynet("wb-upper", upper, :argv, %{})

    assert {:ok, out} =
             BuildBroker.build_and_run(:c, @orchestrator, "",
               allow: true,
               broker: true,
               exec_allow: true,
               commands: ["wb-upper"]
             )

    assert out =~ "RESULT[HELLO WORLD", out
    refute out =~ "DENIED"
  end
end
