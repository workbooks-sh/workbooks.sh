defmodule Workbooks.ServeBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, ServeBroker}

  @tag :build
  @tag timeout: 300_000
  test "inbound serve-flip — host dispatches requests to a persistent guest handler, re-entered per request" do
    serve_id = "s#{System.unique_integer([:positive])}"
    src = Path.join(System.tmp_dir!(), "serve_#{System.unique_integer([:positive])}.c")

    # A C reactor (no _start; exports `handle`) — the established export pattern. handle fetches the request
    # via the brokered import, prefixes "echo:", and returns it via the response import.
    File.write!(src, ~S|
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
static unsigned char buf[256];
static unsigned char resp[261];
__attribute__((export_name("handle"))) int handle(void) {
  int n = host_request_get((int)(long)buf, 256);
  if (n < 0) n = 0;
  if (n > 256) n = 256;
  resp[0]='e'; resp[1]='c'; resp[2]='h'; resp[3]='o'; resp[4]=':';
  for (int i = 0; i < n; i++) resp[5+i] = buf[i];
  host_response_set((int)(long)resp, 5 + n);
  return 0;
}|)

    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    bytes = File.read!(wasm)

    {:ok, pid} =
      Wasmex.start_link(%{bytes: bytes, imports: %{"env" => ServeBroker.imports(serve_id)}})

    # the host owns the "socket"; the guest only ever sees the request bytes and returns response bytes
    assert {:ok, "echo:hello"} = ServeBroker.dispatch(serve_id, pid, "hello")
    # SAME persistent instance handles a second request (handler re-entered, like a long-lived server)
    assert {:ok, "echo:world"} = ServeBroker.dispatch(serve_id, pid, "world")
  end
end
