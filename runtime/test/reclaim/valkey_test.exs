defmodule Workbooks.Reclaim.ValkeyTest do
  @moduledoc """
  RECLAIM: "Valkey" — durably proves the run1 agent claim.

  Claim (resolved.json reclaim): "Built a RESP (Redis/Valkey wire-protocol) guest in C,
  compiled it in-sandbox to a wasm reactor, instantiated it over ServeBroker, and served
  correct PING/SET/GET/DEL/EXISTS frames with stateful round-trips. ... For durability swap
  the in-mem store for StorageBroker.Server.put/get (same plumbing BrokeredApp grants via
  host_kv_*)."

  This test is fully self-contained:
    * compiles a RESP codec C reactor inline (Compilers.compile_c, crt:false),
    * backs it with the DURABLE KV broker (RustDock host_kv_* -> StorageBroker),
    * fronts it with a REAL HTTP listener (Bandit + ServeBroker.Plug),
    * drives PING/SET/GET/DEL/EXISTS over the wire and asserts RESP-correct, STATEFUL replies
      (a value SET in one request is GET in a later request — proving persistence, not echo).

  The RESP frame travels in the HTTP request body; the guest parses the body after the
  blank-line separator of the marshaled request (per ServeBroker.encode_http_request). The
  guest emits the raw RESP reply as the response body (ServeBroker.Plug -> status 200).

  Scope honesty: this is the Valkey/Redis DATA-PLANE wire protocol (RESP) over the brokered
  transport with durable KV — NOT a full Valkey daemon (no pub/sub, no expiry, no clustering).
  That matches exactly the reclaim recipe's stated scope.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  # RESP codec reactor. Commands handled: PING, SET k v, GET k, DEL k, EXISTS k.
  # Storage: durable KV via host_kv_put/get. DEL = store empty value (get of empty => not-exists).
  # Replies are raw RESP: +PONG\r\n / +OK\r\n / $len\r\n<v>\r\n / $-1\r\n / :N\r\n
  @resp_c ~S'''
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);

static unsigned char req[1024];
static unsigned char val[512];
static unsigned char resp[700];

static int eqi(const unsigned char* a, const char* b, int n){
  for(int i=0;i<n;i++){ unsigned char c=a[i]; if(c>='a'&&c<='z') c-=32; if(c!=(unsigned char)b[i]) return 0; }
  return 1;
}

// find the start of the RESP body: after the first "\n\n" of the marshaled HTTP request.
static int body_start(int n){
  for(int i=0;i+1<n;i++) if(req[i]=='\n'&&req[i+1]=='\n') return i+2;
  return 0;
}

// Parse a RESP array of bulk strings: *N\r\n ($len\r\n<bytes>\r\n)*. Fill argv offsets/lens.
// returns argc, with arg pointers into req[]. Falls back to 0 on malformed.
static int argc_;
static int argoff[8]; static int arglen[8];
static int parse_resp(int s, int e){
  argc_=0;
  if(s>=e) return 0;
  if(req[s]!='*') return 0;
  s++;
  int cnt=0; while(s<e && req[s]>='0'&&req[s]<='9'){ cnt=cnt*10+(req[s]-'0'); s++; }
  if(s+1<e && req[s]=='\r' && req[s+1]=='\n') s+=2; else return 0;
  for(int a=0;a<cnt && a<8;a++){
    if(s>=e || req[s]!='$') return 0;
    s++;
    int ln=0; while(s<e && req[s]>='0'&&req[s]<='9'){ ln=ln*10+(req[s]-'0'); s++; }
    if(s+1<e && req[s]=='\r' && req[s+1]=='\n') s+=2; else return 0;
    argoff[a]=s; arglen[a]=ln; s+=ln;
    if(s+1<e && req[s]=='\r' && req[s+1]=='\n') s+=2; else return 0;
  }
  argc_=cnt; return cnt;
}

static int put_str(int p, const char* s){ int i=0; while(s[i]){ resp[p++]=s[i]; i++; } return p; }
static int put_int(int p, int v){ char b[12]; int n=0; if(v==0){ resp[p++]='0'; return p; } int t=v; while(t){ b[n++]='0'+t%10; t/=10; } while(n) resp[p++]=b[--n]; return p; }

__attribute__((export_name("handle"))) int handle(void){
  int n = host_request_get((int)(long)req, 1024); if(n<0)n=0; if(n>1024)n=1024;
  int s = body_start(n);
  int ac = parse_resp(s, n);
  int p = 0;

  if(ac>=1 && arglen[0]==4 && eqi(req+argoff[0],"PING",4)){
    p = put_str(p, "+PONG\r\n");
  } else if(ac>=3 && arglen[0]==3 && eqi(req+argoff[0],"SET",3)){
    host_kv_put((int)(long)(req+argoff[1]), arglen[1], (int)(long)(req+argoff[2]), arglen[2]);
    p = put_str(p, "+OK\r\n");
  } else if(ac>=2 && arglen[0]==3 && eqi(req+argoff[0],"GET",3)){
    int g = host_kv_get((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, 512);
    if(g>0){
      p = put_str(p, "$"); p = put_int(p, g); p = put_str(p, "\r\n");
      for(int i=0;i<g;i++) resp[p++]=val[i];
      p = put_str(p, "\r\n");
    } else {
      p = put_str(p, "$-1\r\n"); // missing OR tombstoned (empty)
    }
  } else if(ac>=2 && arglen[0]==3 && eqi(req+argoff[0],"DEL",3)){
    int g = host_kv_get((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, 512);
    int existed = (g>0) ? 1 : 0;
    host_kv_put((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, 0); // tombstone = empty
    p = put_str(p, ":"); p = put_int(p, existed); p = put_str(p, "\r\n");
  } else if(ac>=2 && arglen[0]==6 && eqi(req+argoff[0],"EXISTS",6)){
    int g = host_kv_get((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, 512);
    p = put_str(p, ":"); p = put_int(p, (g>0)?1:0); p = put_str(p, "\r\n");
  } else {
    p = put_str(p, "-ERR unknown\r\n");
  }
  host_response_set((int)(long)resp, p);
  return 0;
}
'''

  defp compile_reactor(body_c) do
    dir = Path.join([__DIR__, "fixtures", "valkey"])
    File.mkdir_p!(dir)
    src = Path.join(dir, "resp_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.rm(src)
    File.read!(wasm)
  end

  @tag :build
  @tag timeout: 360_000
  test "Valkey RESP data plane — PING/SET/GET/DEL/EXISTS over the wire, durable & stateful" do
    serve_id = "valkey#{System.unique_integer([:positive])}"
    tenant = "valkey-#{System.unique_integer([:positive])}"

    # guest gets BOTH the serve channel and the durable KV broker (host_kv_*)
    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: compile_reactor(@resp_c), imports: %{"env" => env}})

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

    # build a RESP array frame for a command (each arg a bulk string)
    resp_frame = fn args ->
      head = "*#{length(args)}\r\n"
      head <> Enum.map_join(args, fn a -> "$#{byte_size(a)}\r\n#{a}\r\n" end)
    end

    # POST the RESP frame as the request body; the guest parses the body, replies raw RESP.
    cmd = fn args ->
      frame = resp_frame.(args)

      {:ok, {{_, status, _}, _hdrs, body}} =
        :httpc.request(
          :post,
          {~c"http://127.0.0.1:#{port}/", [], ~c"application/octet-stream", frame},
          [],
          body_format: :binary
        )

      assert status == 200
      to_string(body)
    end

    # PING
    assert cmd.(["PING"]) == "+PONG\r\n"

    # key missing first
    assert cmd.(["EXISTS", "color"]) == ":0\r\n"
    assert cmd.(["GET", "color"]) == "$-1\r\n"

    # SET then read back (stateful round-trip across separate HTTP requests => durable KV)
    assert cmd.(["SET", "color", "green"]) == "+OK\r\n"
    assert cmd.(["EXISTS", "color"]) == ":1\r\n"
    assert cmd.(["GET", "color"]) == "$5\r\ngreen\r\n"

    # overwrite
    assert cmd.(["SET", "color", "blueblue"]) == "+OK\r\n"
    assert cmd.(["GET", "color"]) == "$8\r\nblueblue\r\n"

    # a second independent key, with a binary-ish value
    assert cmd.(["SET", "k2", "a:b:c"]) == "+OK\r\n"
    assert cmd.(["GET", "k2"]) == "$5\r\na:b:c\r\n"
    # first key still intact -> not cross-contaminated
    assert cmd.(["GET", "color"]) == "$8\r\nblueblue\r\n"

    # DEL existing returns :1, then EXISTS/GET reflect removal
    assert cmd.(["DEL", "color"]) == ":1\r\n"
    assert cmd.(["EXISTS", "color"]) == ":0\r\n"
    assert cmd.(["GET", "color"]) == "$-1\r\n"

    # DEL of already-removed returns :0
    assert cmd.(["DEL", "color"]) == ":0\r\n"
  end
end
