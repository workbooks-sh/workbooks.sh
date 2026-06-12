defmodule Workbooks.ServeBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

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

  # COMPOSITION demo guest: a caching HTTP server. Per request it reads the request (serve), looks up a KV
  # key (durable storage), and on miss caches the request — composing the serve + kv brokers in ONE sandboxed
  # guest. Wraps responses as "200\n\n<body>" so the Plug's decoder applies status 200.
  defp caching_server_bytes,
    do:
      compile_reactor(~S|
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);
static unsigned char req[256]; static unsigned char keyb[8]; static unsigned char val[256]; static unsigned char resp[320];
__attribute__((export_name("handle"))) int handle(void) {
  int n = host_request_get((int)(long)req, 256); if(n<0)n=0; if(n>256)n=256;
  const char* k="lastreq"; for(int i=0;i<7;i++) keyb[i]=k[i];
  int g = host_kv_get((int)(long)keyb, 7, (int)(long)val, 256);
  resp[0]='2';resp[1]='0';resp[2]='0';resp[3]='\n';resp[4]='\n'; int p=5;
  if (g>0) {
    resp[p++]='H';resp[p++]='I';resp[p++]='T';resp[p++]=':';
    for(int i=0;i<g;i++) resp[p++]=val[i];
  } else {
    resp[p++]='M';resp[p++]='I';resp[p++]='S';resp[p++]='S';resp[p++]=':';
    for(int i=0;i<n;i++) resp[p++]=req[i];
    host_kv_put((int)(long)keyb, 7, (int)(long)req, n);
  }
  host_response_set((int)(long)resp, p);
  return 0;
}|)

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

  @tag :build
  @tag timeout: 300_000
  test "COMPOSITION — a sandboxed serving guest caches in KV per request (serve + durable storage compose)" do
    serve_id = "c#{System.unique_integer([:positive])}"
    tenant = "demo-#{System.unique_integer([:positive])}"

    # one guest, granted BOTH the serve channel and the dock's kv broker — the brokers compose
    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: caching_server_bytes(), imports: %{"env" => env}})

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

    get = fn path ->
      {:ok, {{_, s, _}, _, b}} =
        :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", []}, [], body_format: :binary)

      {s, to_string(b)}
    end

    # first request: cache MISS -> the guest computes + caches it via the kv broker
    {s1, b1} = get.("/first")
    assert s1 == 200
    assert b1 =~ "MISS:GET /first"

    # second request: cache HIT -> the guest returns the FIRST request, which persisted via durable KV.
    # Proves serve + storage compose into a real stateful sandboxed app.
    {s2, b2} = get.("/second")
    assert s2 == 200
    assert b2 =~ "HIT:GET /first"
  end
end
