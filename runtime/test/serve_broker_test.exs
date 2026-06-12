defmodule Workbooks.ServeBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, ServeBroker}

  # --- hermetic marshaling (no guest) ---

  test "encode_http_request shapes request line + forwarded headers + blank + binary body" do
    req = ServeBroker.encode_http_request("GET", "/p", [{"x-a", "1"}, {"x-b", "2"}], "BO\0DY")
    assert req == "GET /p\nx-a: 1\nx-b: 2\n\nBO\0DY"
  end

  test "decode_http_response parses status + headers + binary body; plain bytes -> 200" do
    assert {201, [{"x-guest", "hi"}, {"content-type", "text/plain"}], "the\n\nbody"} =
             ServeBroker.decode_http_response("201\nx-guest: hi\ncontent-type: text/plain\n\nthe\n\nbody")

    assert {200, [], "plain"} = ServeBroker.decode_http_response("plain")
    assert {404, [], ""} = ServeBroker.decode_http_response("404\n\n")
  end

  # --- guests ---

  defp compile_reactor(body_c) do
    src = Path.join(System.tmp_dir!(), "serve_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.read!(wasm)
  end

  # echoes the raw request with an "echo:" prefix
  defp echo_bytes,
    do:
      compile_reactor(~S|
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
static unsigned char buf[256]; static unsigned char resp[261];
__attribute__((export_name("handle"))) int handle(void) {
  int n = host_request_get((int)(long)buf, 256); if (n<0) n=0; if (n>256) n=256;
  resp[0]='e';resp[1]='c';resp[2]='h';resp[3]='o';resp[4]=':';
  for (int i=0;i<n;i++) resp[5+i]=buf[i];
  host_response_set((int)(long)resp, 5+n); return 0;
}|)

  # returns a STRUCTURED response: status 201 + a header + the echoed request as body
  defp rich_bytes,
    do:
      compile_reactor(~S|
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
static unsigned char buf[512]; static unsigned char resp[700];
__attribute__((export_name("handle"))) int handle(void) {
  int n = host_request_get((int)(long)buf, 512); if (n<0) n=0; if (n>512) n=512;
  const char* h = "201\nx-guest: hi\n\necho:";
  int k=0; while (h[k]) { resp[k]=h[k]; k++; }
  for (int i=0;i<n;i++) resp[k+i]=buf[i];
  host_response_set((int)(long)resp, k+n); return 0;
}|)

  defp serving_guest(bytes, serve_id) do
    {:ok, pid} = Wasmex.start_link(%{bytes: bytes, imports: %{"env" => ServeBroker.imports(serve_id)}})
    pid
  end

  @tag :build
  @tag timeout: 300_000
  test "serve-flip core — host dispatches to a persistent guest handler, re-entered per request" do
    serve_id = "s#{System.unique_integer([:positive])}"
    pid = serving_guest(echo_bytes(), serve_id)

    assert {:ok, "echo:hello"} = ServeBroker.dispatch(serve_id, pid, "hello")
    assert {:ok, "echo:world"} = ServeBroker.dispatch(serve_id, pid, "world")
  end

  @tag :build
  @tag timeout: 300_000
  test "host-as-listener — REAL HTTP request served by the guest, who sets status+headers and sees req headers" do
    serve_id = "h#{System.unique_integer([:positive])}"
    pid = serving_guest(rich_bytes(), serve_id)
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
    url = ~c"http://127.0.0.1:#{port}/rich"

    {:ok, {{_, status, _}, hdrs, body}} =
      :httpc.request(:get, {url, [{~c"x-foo", ~c"bar"}]}, [], body_format: :binary)

    body = to_string(body)
    # the GUEST set the status + header
    assert status == 201
    assert {~c"x-guest", ~c"hi"} in hdrs
    # the guest received the marshaled request (incl the forwarded x-foo header) and echoed it
    assert body =~ "echo:GET /rich"
    assert body =~ "x-foo: bar"
  end
end
