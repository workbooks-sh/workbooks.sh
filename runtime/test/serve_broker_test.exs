defmodule Workbooks.ServeBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, ServeBroker}

  # A C reactor (no _start; exports `handle`) — fetches the request via the brokered import, prefixes
  # "echo:", returns it via the response import. Reused by both tests.
  defp echo_guest_bytes do
    src = Path.join(System.tmp_dir!(), "serve_#{System.unique_integer([:positive])}.c")

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
    File.read!(wasm)
  end

  defp serving_guest(serve_id) do
    {:ok, pid} =
      Wasmex.start_link(%{bytes: echo_guest_bytes(), imports: %{"env" => ServeBroker.imports(serve_id)}})

    pid
  end

  @tag :build
  @tag timeout: 300_000
  test "serve-flip core — host dispatches to a persistent guest handler, re-entered per request" do
    serve_id = "s#{System.unique_integer([:positive])}"
    pid = serving_guest(serve_id)

    assert {:ok, "echo:hello"} = ServeBroker.dispatch(serve_id, pid, "hello")
    # SAME persistent instance handles a second request (handler re-entered, like a long-lived server)
    assert {:ok, "echo:world"} = ServeBroker.dispatch(serve_id, pid, "world")
  end

  @tag :build
  @tag timeout: 300_000
  test "host-as-listener — a REAL HTTP request is served end-to-end by the guest handler" do
    serve_id = "h#{System.unique_integer([:positive])}"
    pid = serving_guest(serve_id)

    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {Workbooks.ServeBroker.Plug, serve_id: serve_id, pid: pid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)

    _ = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}/hello"
    {:ok, {{_, status, _}, _hdrs, body}} = :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert status == 200
    # the guest handler saw the marshaled request and echoed it; this body came FROM the sandboxed guest
    assert to_string(body) == "echo:GET /hello\n\n"
  end
end
