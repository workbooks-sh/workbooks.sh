defmodule Workbooks.Reclaim.TarantoolTest do
  @moduledoc """
  RECLAIM: "Tarantool" — durably proves the run1 agent claim.

  Claim (resolved.json reclaim): "Tarantool's IProto core data op (REPLACE/SELECT a tuple by
  primary key in a durable space) ... a ServeBroker reactor guest decoding an IProto-style
  request frame (here a minimal SET/GET binary frame standing in for IProto REPLACE/SELECT),
  tuples persisted in StorageBroker durable KV via RustDock host_kv_put/get, response written
  via host_response_set, fronted by ServeBroker.Plug/BrokeredApp over the host listener. ...
  NOT reproduced: Tarantool's embedded Lua application server and secondary indexes — only the
  primary-key space data plane."

  Self-contained test:
    * compiles an IProto-style binary-frame space engine C reactor inline,
    * persists tuples in the DURABLE KV broker (host_kv_*), keyed by primary key,
    * fronts it with a REAL HTTP listener (Bandit + ServeBroker.Plug),
    * issues REPLACE then SELECT-by-primary-key binary frames over the wire and asserts the
      durable tuple round-trips (a tuple REPLACEd in one request is SELECTed back in a later one).

  Honesty on scope: this is the IProto primary-key SPACE DATA PLANE (REPLACE/SELECT/DELETE by
  primary key) over the brokered transport with durable persistence — explicitly NOT the full
  msgpack IProto codec, the embedded Lua app server, or secondary indexes. That matches the
  reclaim recipe's stated scope.

  Binary frame format (carried in the HTTP request body, after the marshaled-request blank line):
    request:  [u8 op][u8 keylen][key bytes][u16le vallen][val bytes]
              op: 1=REPLACE (key+val), 2=SELECT (key only), 3=DELETE (key only)
    response: REPLACE -> [u8 0x00] (ok)
              SELECT  -> hit:  [u8 0x01][u16le vallen][val bytes]
                         miss: [u8 0x02]
              DELETE  -> [u8 0x01] if existed else [u8 0x02]
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  @iproto_c ~S'''
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);

static unsigned char req[2048];
static unsigned char val[1024];
static unsigned char resp[1100];

static int body_start(int n){
  for(int i=0;i+1<n;i++) if(req[i]=='\n'&&req[i+1]=='\n') return i+2;
  return 0;
}

__attribute__((export_name("handle"))) int handle(void){
  int n = host_request_get((int)(long)req, 2048); if(n<0)n=0; if(n>2048)n=2048;
  int s = body_start(n);
  if(s+2 > n){ resp[0]=0x02; host_response_set((int)(long)resp,1); return 0; }

  int op   = req[s];
  int klen = req[s+1];
  int kp   = s+2;
  if(kp+klen > n){ resp[0]=0x02; host_response_set((int)(long)resp,1); return 0; }

  if(op==1){ // REPLACE: key + u16le vallen + val
    int vlp = kp+klen;
    int vlen = req[vlp] | (req[vlp+1]<<8);
    int vp = vlp+2;
    host_kv_put((int)(long)(req+kp), klen, (int)(long)(req+vp), vlen);
    resp[0]=0x00;
    host_response_set((int)(long)resp,1); return 0;
  }
  if(op==2){ // SELECT by primary key
    int g = host_kv_get((int)(long)(req+kp), klen, (int)(long)val, 1024);
    if(g>0){
      resp[0]=0x01; resp[1]=g&0xff; resp[2]=(g>>8)&0xff;
      for(int i=0;i<g;i++) resp[3+i]=val[i];
      host_response_set((int)(long)resp, 3+g);
    } else {
      resp[0]=0x02; host_response_set((int)(long)resp,1);
    }
    return 0;
  }
  if(op==3){ // DELETE by primary key (tombstone via empty value)
    int g = host_kv_get((int)(long)(req+kp), klen, (int)(long)val, 1024);
    int existed = (g>0)?1:0;
    host_kv_put((int)(long)(req+kp), klen, (int)(long)val, 0);
    resp[0] = existed ? 0x01 : 0x02;
    host_response_set((int)(long)resp,1); return 0;
  }
  resp[0]=0x02; host_response_set((int)(long)resp,1); return 0;
}
'''

  defp compile_reactor(body_c) do
    dir = Path.join([__DIR__, "fixtures", "tarantool"])
    File.mkdir_p!(dir)
    src = Path.join(dir, "iproto_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.rm(src)
    File.read!(wasm)
  end

  # frame builders
  defp replace_frame(key, val),
    do: <<1, byte_size(key)::8, key::binary, byte_size(val)::little-16, val::binary>>

  defp select_frame(key), do: <<2, byte_size(key)::8, key::binary>>
  defp delete_frame(key), do: <<3, byte_size(key)::8, key::binary>>

  @tag :build
  @tag timeout: 360_000
  test "Tarantool IProto space data plane — REPLACE/SELECT/DELETE a tuple by primary key, durable" do
    serve_id = "trnt#{System.unique_integer([:positive])}"
    tenant = "trnt-#{System.unique_integer([:positive])}"

    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: compile_reactor(@iproto_c), imports: %{"env" => env}})

    port = 46_000 + rem(System.unique_integer([:positive]), 3_000)

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

    send_frame = fn frame ->
      {:ok, {{_, status, _}, _h, body}} =
        :httpc.request(
          :post,
          {~c"http://127.0.0.1:#{port}/", [], ~c"application/octet-stream", frame},
          [],
          body_format: :binary
        )

      assert status == 200
      body
    end

    # SELECT a non-existent primary key -> miss (0x02)
    assert send_frame.(select_frame("pk1")) == <<0x02>>

    # REPLACE a tuple (primary key "pk1" -> tuple bytes) -> ok (0x00)
    tuple1 = <<"name=alice;age=30">>
    assert send_frame.(replace_frame("pk1", tuple1)) == <<0x00>>

    # SELECT by primary key -> hit, exact durable tuple comes back (separate HTTP request)
    assert send_frame.(select_frame("pk1")) ==
             <<0x01, byte_size(tuple1)::little-16, tuple1::binary>>

    # REPLACE the same key (upsert semantics) with a new tuple
    tuple1b = <<"name=alice;age=31;city=nyc">>
    assert send_frame.(replace_frame("pk1", tuple1b)) == <<0x00>>
    assert send_frame.(select_frame("pk1")) ==
             <<0x01, byte_size(tuple1b)::little-16, tuple1b::binary>>

    # a second independent primary key, with binary (non-text) tuple bytes
    tuple2 = <<0, 1, 2, 250, 200, 7>>
    assert send_frame.(replace_frame("pk2", tuple2)) == <<0x00>>
    assert send_frame.(select_frame("pk2")) ==
             <<0x01, byte_size(tuple2)::little-16, tuple2::binary>>

    # first key still intact -> the space holds distinct tuples by primary key
    assert send_frame.(select_frame("pk1")) ==
             <<0x01, byte_size(tuple1b)::little-16, tuple1b::binary>>

    # DELETE existing -> existed (0x01); subsequent SELECT misses
    assert send_frame.(delete_frame("pk1")) == <<0x01>>
    assert send_frame.(select_frame("pk1")) == <<0x02>>
    # pk2 untouched
    assert send_frame.(select_frame("pk2")) ==
             <<0x01, byte_size(tuple2)::little-16, tuple2::binary>>

    # DELETE of an already-removed key -> not-existed (0x02)
    assert send_frame.(delete_frame("pk1")) == <<0x02>>
  end
end
