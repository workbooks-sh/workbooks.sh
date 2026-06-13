defmodule Workbooks.Reclaim.RedisTest do
  @moduledoc """
  RECLAIM — Redis (RESP-over-TCP) made DURABLE.

  Reproduces the run1 agent's in-sandbox proof: a RESP-protocol guest (compiled C via the in-sandbox
  clang lane) that parses Redis client frames and emits valid RESP for PING/SET/GET/DEL. The HOST owns
  the raw-TCP listener (TcpServeBroker — the privileged op a sandboxed guest can never have); per
  command the inbound RESP bytes are handed to the sandboxed wasm guest (ServeBroker.dispatch), which
  parses argv, dispatches, and uses the durable KV Dock imports (StorageBroker, tenant-isolated) for
  SET/GET/DEL. State persists across connections in the durable KV. We talk to it with a REAL TCP
  client speaking the RESP wire protocol — a fully serving Redis-compatible endpoint.

  Everything is built inline (compile the RESP guest, wire RustDock KV + ServeBroker imports, serve
  over a host-owned raw-TCP socket). Honest scope: PING/SET/GET/DEL over RESP with durable state is
  proven; pub/sub, the full command set, RDB/AOF fork-persistence, and cluster are NOT emulated — the
  RESP line-protocol transport + a KV-backed command core is what round-trips here.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker, TcpServeBroker}

  # RESP guest. Parses the client's `*N\r\n$len\r\n<arg>\r\n...` array-of-bulk-strings frame into argv,
  # then dispatches. No libc (links under crt:false). Replies in RESP:
  #   PING            -> +PONG\r\n
  #   SET k v         -> +OK\r\n        (host_kv_put)
  #   GET k           -> $<len>\r\n<v>\r\n  | $-1\r\n (nil)   (host_kv_get)
  #   DEL k           -> :1\r\n          (we put an empty value as a tombstone; GET then returns nil)
  #   (unknown)       -> -ERR unknown\r\n
  @guest_c ~S"""
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);

static unsigned char req[8192];
static unsigned char out[16384];
static unsigned char val[8192];

// argv: up to 4 args, each a (ptr-offset,len) into req
static int argoff[8];
static int arglen[8];

static int ci(unsigned char c){ if(c>='a'&&c<='z') return c-32; return c; } // ASCII upper
static int streq_ci(int off, int len, const char* s){
  int n=0; while(s[n]) n++;
  if(len!=n) return 0;
  for(int i=0;i<len;i++){ if(ci(req[off+i]) != s[i]) return 0; }
  return 1;
}
static int fmtint(int v, unsigned char* s){ // non-neg ints only
  if(v==0){ s[0]='0'; return 1; }
  unsigned char t[12]; int i=0; while(v>0){ t[i++]='0'+(v%10); v/=10; }
  for(int j=0;j<i;j++) s[j]=t[i-1-j]; return i;
}

__attribute__((export_name("handle"))) int handle(void){
  int rn = host_request_get((int)(long)req, sizeof(req)); if(rn<0) rn=0;

  // ---- parse RESP array of bulk strings ----
  int argc=0, i=0;
  if(rn>0 && req[i]=='*'){
    i++;
    int n=0; while(i<rn && req[i]>='0' && req[i]<='9'){ n=n*10+(req[i]-'0'); i++; }
    // skip \r\n
    if(i+1<rn && req[i]=='\r') i+=2;
    for(int a=0; a<n && a<8; a++){
      if(i>=rn || req[i]!='$') break;
      i++;
      int len=0; while(i<rn && req[i]>='0' && req[i]<='9'){ len=len*10+(req[i]-'0'); i++; }
      if(i+1<rn && req[i]=='\r') i+=2;
      argoff[a]=i; arglen[a]=len;
      i+=len;
      if(i+1<rn && req[i]=='\r') i+=2;
      argc++;
    }
  }

  int o=0;
  if(argc>=1 && streq_ci(argoff[0], arglen[0], "PING")){
    const char* p="+PONG\r\n"; for(int j=0;p[j];j++) out[o++]=p[j];
  } else if(argc>=3 && streq_ci(argoff[0], arglen[0], "SET")){
    host_kv_put((int)(long)(req+argoff[1]), arglen[1], (int)(long)(req+argoff[2]), arglen[2]);
    const char* p="+OK\r\n"; for(int j=0;p[j];j++) out[o++]=p[j];
  } else if(argc>=2 && streq_ci(argoff[0], arglen[0], "GET")){
    int vl = host_kv_get((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, sizeof(val));
    if(vl < 0 || vl == 0){
      const char* p="$-1\r\n"; for(int j=0;p[j];j++) out[o++]=p[j];  // nil / tombstoned
    } else {
      out[o++]='$';
      o += fmtint(vl, out+o);
      out[o++]='\r'; out[o++]='\n';
      for(int j=0;j<vl;j++) out[o++]=val[j];
      out[o++]='\r'; out[o++]='\n';
    }
  } else if(argc>=2 && streq_ci(argoff[0], arglen[0], "DEL")){
    // tombstone: store empty value; GET treats len==0 as nil
    host_kv_put((int)(long)(req+argoff[1]), arglen[1], (int)(long)val, 0);
    const char* p=":1\r\n"; for(int j=0;p[j];j++) out[o++]=p[j];
  } else {
    const char* p="-ERR unknown command\r\n"; for(int j=0;p[j];j++) out[o++]=p[j];
  }

  host_response_set((int)(long)out, o);
  return 0;
}
"""

  setup_all do
    src = Path.join(System.tmp_dir!(), "redis_reclaim_#{System.unique_integer([:positive])}.c")
    File.write!(src, @guest_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    %{wasm: File.read!(wasm)}
  end

  # Build a (binary -> binary) handler backed by the SANDBOXED RESP wasm guest. The host owns the TCP
  # socket; this handler drives each connection's raw RESP bytes through the guest via ServeBroker.
  defp resp_handler(wasm, tenant) do
    serve_id = "redis-#{System.unique_integer([:positive])}"
    dock = RustDock.imports(profile: :network, tenant: tenant)["env"]
    env = Map.merge(dock, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: wasm, imports: %{"env" => env}})

    fn request ->
      case ServeBroker.dispatch(serve_id, pid, request) do
        {:ok, resp} -> resp
        {:error, _} -> "-ERR guest\r\n"
      end
    end
  end

  defp start_server(wasm, tenant) do
    handler = resp_handler(wasm, tenant)
    {:ok, lsock} = TcpServeBroker.start(handler: handler)
    on_exit(fn -> TcpServeBroker.stop(lsock) end)
    TcpServeBroker.port(lsock)
  end

  # RESP-encode a command (array of bulk strings) the way redis-cli does.
  defp resp_cmd(args) do
    parts =
      Enum.map(args, fn a -> "$#{byte_size(a)}\r\n#{a}\r\n" end)

    "*#{length(args)}\r\n" <> Enum.join(parts)
  end

  # one command per connection (matches TcpServeBroker's one-req/one-resp-per-connection model)
  defp cmd(port, args) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    :ok = :gen_tcp.send(sock, resp_cmd(args))
    resp = recv_all(sock, "")
    :gen_tcp.close(sock)
    resp
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 1_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  @tag :build
  @tag timeout: 600_000
  test "RESP over a host-owned TCP socket: PING/SET/GET/DEL round-trip, state durable in KV",
       %{wasm: wasm} do
    tenant = "redis-#{System.unique_integer([:positive])}"
    port = start_server(wasm, tenant)

    # PING -> +PONG
    assert cmd(port, ["PING"]) == "+PONG\r\n"

    # GET on a missing key -> nil
    assert cmd(port, ["GET", "color"]) == "$-1\r\n"

    # SET -> +OK
    assert cmd(port, ["SET", "color", "green"]) == "+OK\r\n"

    # GET returns the value as a RESP bulk string (state survived the prior connection close ->
    # durable in StorageBroker KV, not in any per-connection memory)
    assert cmd(port, ["GET", "color"]) == "$5\r\ngreen\r\n"

    # overwrite + read back
    assert cmd(port, ["SET", "color", "ff00ff-magenta"]) == "+OK\r\n"
    assert cmd(port, ["GET", "color"]) == "$14\r\nff00ff-magenta\r\n"

    # DEL -> :1, then GET -> nil
    assert cmd(port, ["DEL", "color"]) == ":1\r\n"
    assert cmd(port, ["GET", "color"]) == "$-1\r\n"

    # a case-insensitive verb (real redis-cli uppercases; clients may send lowercase) still works
    assert cmd(port, ["set", "k2", "v2"]) == "+OK\r\n"
    assert cmd(port, ["get", "k2"]) == "$2\r\nv2\r\n"
  end

  @tag :build
  @tag timeout: 600_000
  test "state is DURABLE across a guest-instance restart (the wasm instance is ephemeral, data is not)",
       %{wasm: wasm} do
    tenant = "redis-persist-#{System.unique_integer([:positive])}"
    port1 = start_server(wasm, tenant)
    assert cmd(port1, ["SET", "persisted", "yes"]) == "+OK\r\n"

    # bring up a FRESH server + FRESH wasm instance bound to the SAME durable tenant namespace
    port2 = start_server(wasm, tenant)
    # the value written by the first instance is visible to the second -> it lives in durable KV
    assert cmd(port2, ["GET", "persisted"]) == "$3\r\nyes\r\n"
  end
end
