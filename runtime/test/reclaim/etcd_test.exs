defmodule Workbooks.Reclaim.EtcdTest do
  @moduledoc """
  RECLAIM (resolved.json["etcd"]): the etcd v2 single-node KV-API surface, in-sandbox.

  Recipe: "Built an etcd v2 KV-API reactor guest served over the host listener
  (ServeBroker) with durable state in StorageBroker; full set/get/update/404/delete
  lifecycle works with real etcd JSON responses. ... grant it RustDock
  host_kv_put/host_kv_get (tenant-scoped durable StorageBroker) + ServeBroker.imports;
  mount on Bandit via ServeBroker.Plug (route /v2/keys/*). DELETE = empty-value tombstone."

  This test compiles that exact reactor INLINE (C, exporting `handle`), grants it BOTH
  the dock KV broker and the serve channel, mounts it on a REAL Bandit listener, and
  exercises the full lifecycle over real HTTP with an etcd v2 client shape:
    PUT  /v2/keys/foo  value=bar      -> 200 {"action":"set", node:{value:"bar"}}
    GET  /v2/keys/foo                 -> 200 {"action":"get", node:{value:"bar"}}
    PUT  /v2/keys/foo  value=baz      -> 200 {"action":"set", node:{value:"baz"}} (update)
    GET  /v2/keys/missing             -> 404 {"errorCode":100,...}
    DELETE /v2/keys/foo               -> tombstone; subsequent GET -> 404

  Honest scope: this is the v2 client HTTP/JSON KV API ONLY — NOT v3 gRPC, NOT raft
  multi-node consensus (the recipe says these are explicitly not emulated). The test
  asserts exactly the v2 KV surface and nothing more.

  @tag :build — needs clang.wasm.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  @moduletag :build
  @compilers_root Path.expand("../../compilers", __DIR__)

  # The etcd v2 reactor. Parses "METHOD /v2/keys/<key>\n<headers>\n\n<body>".
  # Body for PUT carries "value=<v>" (form-encoded, as etcdctl/curl send). State is
  # durable via host_kv_put/host_kv_get. DELETE writes an empty value (tombstone);
  # GET treats a zero-length value as not-found (404), per the recipe.
  @etcd_reactor ~S"""
  __attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
  __attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
  __attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
  __attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);

  static unsigned char req[1024];
  static unsigned char key[256];
  static unsigned char val[512];
  static unsigned char resp[1200];

  static int streq(const unsigned char* a, const char* b, int n){ for(int i=0;i<n;i++){ if(a[i]!=(unsigned char)b[i]) return 0; } return 1; }
  static int emit(unsigned char* d, const char* s){ int i=0; while(s[i]){ d[i]=s[i]; i++; } return i; }

  __attribute__((export_name("handle"))) int handle(void) {
    int n = host_request_get((int)(long)req, 1024); if(n<0)n=0; if(n>1024)n=1024;

    /* method */
    int method = 0; /* 0=GET 1=PUT 2=DELETE 3=other */
    int i = 0;
    if (n>=3 && streq(req, "GET", 3)) { method=0; i=3; }
    else if (n>=3 && streq(req, "PUT", 3)) { method=1; i=3; }
    else if (n>=6 && streq(req, "DELETE", 6)) { method=2; i=6; }
    else { method=3; }
    while (i<n && req[i]==' ') i++;

    /* path: expect /v2/keys/<key> ; key = path after "/v2/keys/" up to space/newline */
    int klen = 0;
    const char* pfx = "/v2/keys/"; int pl = 9;
    if (i+pl <= n && streq(req+i, pfx, pl)) {
      i += pl;
      while (i<n && req[i] != ' ' && req[i] != '\n' && req[i] != '\r' && klen < 255) {
        key[klen++] = req[i++];
      }
    }

    /* find body (after the blank line "\n\n") */
    int bstart = -1;
    for (int j=0; j+1<n; j++) { if (req[j]=='\n' && req[j+1]=='\n') { bstart = j+2; break; } }

    int p = 0;
    if (method == 3 || klen == 0) {
      p = emit(resp, "400\n\n{\"errorCode\":1,\"message\":\"bad request\"}");
      host_response_set((int)(long)resp, p); return 0;
    }

    if (method == 1) { /* PUT/set: body value=<v> */
      /* probe existence FIRST (into resp scratch) so we can report prevExist on update */
      int existed = host_kv_get((int)(long)key, klen, (int)(long)resp, 512);
      int vlen = 0;
      if (bstart >= 0) {
        int b = bstart;
        /* skip leading "value=" if present */
        if (b+6 <= n && streq(req+b, "value=", 6)) b += 6;
        while (b<n && vlen < 511) { val[vlen++] = req[b++]; }
      }
      host_kv_put((int)(long)key, klen, (int)(long)val, vlen);
      p = emit(resp, "200\n\n{\"action\":\"set\",\"node\":{\"key\":\"/");
      for (int k=0;k<klen;k++) resp[p++]=key[k];
      p += emit(resp+p, "\",\"value\":\"");
      for (int k=0;k<vlen;k++) resp[p++]=val[k];
      p += emit(resp+p, "\"}");
      if (existed > 0) { p += emit(resp+p, ",\"prevExist\":true"); }
      resp[p++]='}';
      host_response_set((int)(long)resp, p); return 0;
    }

    if (method == 0) { /* GET */
      int g = host_kv_get((int)(long)key, klen, (int)(long)val, 512);
      if (g <= 0) { /* missing or tombstoned */
        p = emit(resp, "404\n\n{\"errorCode\":100,\"message\":\"Key not found\",\"cause\":\"/");
        for (int k=0;k<klen;k++) resp[p++]=key[k];
        p += emit(resp+p, "\"}");
        host_response_set((int)(long)resp, p); return 0;
      }
      p = emit(resp, "200\n\n{\"action\":\"get\",\"node\":{\"key\":\"/");
      for (int k=0;k<klen;k++) resp[p++]=key[k];
      p += emit(resp+p, "\",\"value\":\"");
      for (int k=0;k<g && k<512;k++) resp[p++]=val[k];
      p += emit(resp+p, "\"}}");
      host_response_set((int)(long)resp, p); return 0;
    }

    /* DELETE: tombstone = put empty value */
    int g = host_kv_get((int)(long)key, klen, (int)(long)val, 512);
    if (g <= 0) {
      p = emit(resp, "404\n\n{\"errorCode\":100,\"message\":\"Key not found\"}");
      host_response_set((int)(long)resp, p); return 0;
    }
    host_kv_put((int)(long)key, klen, (int)(long)val, 0); /* zero-length tombstone */
    p = emit(resp, "200\n\n{\"action\":\"delete\",\"node\":{\"key\":\"/");
    for (int k=0;k<klen;k++) resp[p++]=key[k];
    p += emit(resp+p, "\"}}");
    host_response_set((int)(long)resp, p); return 0;
  }
  """

  defp etcd_guest(serve_id, tenant) do
    src = Path.join(System.tmp_dir!(), "etcd_v2_#{System.unique_integer([:positive])}.c")
    File.write!(src, @etcd_reactor)

    {:ok, wasm, _} =
      Compilers.compile_c(src, [crt: false, ld_args: ["--no-entry", "--export-memory"]], @compilers_root)

    wasm_bytes = File.read!(wasm)
    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: wasm_bytes, imports: %{"env" => env}})
    pid
  end

  @tag timeout: 600_000
  test "etcd v2 KV API: full set/get/update/404/delete lifecycle over real HTTP with etcd JSON" do
    serve_id = "etcd-#{System.unique_integer([:positive])}"
    tenant = "etcd-tenant-#{System.unique_integer([:positive])}"
    pid = etcd_guest(serve_id, tenant)

    port = 47_000 + rem(System.unique_integer([:positive]), 3_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {ServeBroker.Plug, serve_id: serve_id, pid: pid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)

    base = ~c"http://127.0.0.1:#{port}"

    put = fn key, value ->
      {:ok, {{_, s, _}, _, b}} =
        :httpc.request(
          :put,
          {~c"#{base}/v2/keys/#{key}", [], ~c"application/x-www-form-urlencoded",
           ~c"value=#{value}"},
          [],
          body_format: :binary
        )

      {s, to_string(b)}
    end

    get = fn key ->
      {:ok, {{_, s, _}, _, b}} =
        :httpc.request(:get, {~c"#{base}/v2/keys/#{key}", []}, [], body_format: :binary)

      {s, to_string(b)}
    end

    del = fn key ->
      {:ok, {{_, s, _}, _, b}} =
        :httpc.request(:delete, {~c"#{base}/v2/keys/#{key}", []}, [], body_format: :binary)

      {s, to_string(b)}
    end

    # 1) SET
    {s1, b1} = put.("foo", "bar")
    assert s1 == 200, "set should be 200, got #{s1}: #{b1}"
    assert b1 =~ ~s("action":"set")
    assert b1 =~ ~s("value":"bar")

    # 2) GET (durable read-back of what we set)
    {s2, b2} = get.("foo")
    assert s2 == 200
    assert b2 =~ ~s("action":"get")
    assert b2 =~ ~s("value":"bar")

    # 3) UPDATE (set over an existing key — durable state mutated)
    {s3, b3} = put.("foo", "baz")
    assert s3 == 200
    assert b3 =~ ~s("value":"baz")
    assert b3 =~ ~s("prevExist":true), "update over existing key should report prevExist"

    {_, b3g} = get.("foo")
    assert b3g =~ ~s("value":"baz"), "the updated value must persist"

    # 4) 404 on a missing key (real etcd errorCode 100)
    {s4, b4} = get.("nope-#{System.unique_integer([:positive])}")
    assert s4 == 404
    assert b4 =~ ~s("errorCode":100)
    assert b4 =~ "Key not found"

    # 5) DELETE (tombstone) then GET -> 404
    {s5, b5} = del.("foo")
    assert s5 == 200
    assert b5 =~ ~s("action":"delete")

    {s6, b6} = get.("foo")
    assert s6 == 404, "deleted key must read as not-found (tombstone), got #{s6}: #{b6}"
    assert b6 =~ ~s("errorCode":100)

    IO.puts("\n[etcd/v2] set/get/update/404/delete lifecycle over real HTTP — all assertions held")
  end
end
