defmodule Workbooks.Reclaim.TimescaleDBTest do
  @moduledoc """
  RECLAIM: "TimescaleDB" — durably proves the run1 agent claim.

  Claim (resolved.json reclaim): "Built a reactor guest that serves TimescaleDB's core
  hypertable op — time_bucket(N) continuous aggregate — over the serve-flip, with durable KV
  available for state, and proved it answers a real query. ... Core TSDB ops (ingest,
  time_bucket, AVG/SUM/MIN/MAX, retention) are integer/float aggregation the C lane handles."

  Self-contained test:
    * compiles a hypertable/time-series engine C reactor inline,
    * persists the hypertable rows in the DURABLE KV broker (read-modify-write a packed series),
    * fronts it with a REAL HTTP listener (Bandit + ServeBroker.Plug),
    * INGESTs rows across separate HTTP requests, then runs a time_bucket(width) continuous
      aggregate query and asserts the AVG/SUM/MIN/MAX/COUNT per bucket are correct against an
      independently-computed Elixir reference.

  Honesty on scope: this reproduces TimescaleDB's signature DATA op — time_bucket continuous
  aggregation over a hypertable — NOT the Postgres-extension surface (no SQL parser, no pgwire,
  no compression policy). That matches the reclaim recipe's stated scope exactly (a PG-wire
  codec "can wrap the same handle()" is explicitly listed as NOT done).

  Wire format (line protocol, in the HTTP request body):
    "INGEST <ts> <val>"   -> appends a row (ts: int seconds, val: int) ; replies "OK <count>"
    "BUCKET <width>"      -> time_bucket(width) groups; replies one line per non-empty bucket:
                             "<bucket_start> count=<c> sum=<s> min=<mn> max=<mx> avg=<a>"
                             (avg = integer floor of sum/count), buckets ascending.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  # rows persisted as packed pairs of int32 (ts, val) in KV key "series".
  @tsdb_c ~S'''
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);

static unsigned char req[1024];
static unsigned char ser[8192];   // packed rows: int32 ts, int32 val (LE)
static unsigned char resp[4096];

static int rd32(unsigned char* b, int p){ return (int)(b[p] | (b[p+1]<<8) | (b[p+2]<<16) | ((unsigned)b[p+3]<<24)); }
static void wr32(unsigned char* b, int p, int v){ b[p]=v&0xff; b[p+1]=(v>>8)&0xff; b[p+2]=(v>>16)&0xff; b[p+3]=(v>>24)&0xff; }

static int body_start(int n){
  for(int i=0;i+1<n;i++) if(req[i]=='\n'&&req[i+1]=='\n') return i+2;
  return 0;
}
// parse signed int starting at *pp within [s,e); advances *pp past it; skips leading spaces.
static int parse_int(int* pp, int e){
  int p=*pp; while(p<e && req[p]==' ') p++;
  int sign=1; if(p<e && req[p]=='-'){ sign=-1; p++; }
  int v=0; while(p<e && req[p]>='0'&&req[p]<='9'){ v=v*10+(req[p]-'0'); p++; }
  *pp=p; return sign*v;
}
static int put_str(int p, const char* s){ int i=0; while(s[i]){ resp[p++]=s[i]; i++; } return p; }
static int put_int(int p, int v){
  if(v<0){ resp[p++]='-'; v=-v; }
  char b[12]; int n=0; if(v==0){ resp[p++]='0'; return p; }
  int t=v; while(t){ b[n++]='0'+t%10; t/=10; } while(n) resp[p++]=b[--n]; return p;
}

__attribute__((export_name("handle"))) int handle(void){
  int n = host_request_get((int)(long)req, 1024); if(n<0)n=0; if(n>1024)n=1024;
  int s = body_start(n);
  // load series from durable KV
  int slen = host_kv_get((int)(long)"series", 6, (int)(long)ser, 8192);
  if(slen<0) slen=0;
  int nrows = slen/8;

  int p = s;
  // command keyword
  if(s+6<=n && req[s]=='I'&&req[s+1]=='N'&&req[s+2]=='G'&&req[s+3]=='E'&&req[s+4]=='S'&&req[s+5]=='T'){
    p = s+6;
    int ts = parse_int(&p, n);
    int v  = parse_int(&p, n);
    wr32(ser, slen, ts); wr32(ser, slen+4, v); slen+=8; nrows++;
    host_kv_put((int)(long)"series", 6, (int)(long)ser, slen);
    int rp=0; rp=put_str(rp,"OK "); rp=put_int(rp,nrows);
    host_response_set((int)(long)resp, rp); return 0;
  }
  if(s+6<=n && req[s]=='B'&&req[s+1]=='U'&&req[s+2]=='C'&&req[s+3]=='K'&&req[s+4]=='E'&&req[s+5]=='T'){
    p = s+6;
    int w = parse_int(&p, n); if(w<=0) w=1;
    // find min/max bucket
    int rp=0;
    // determine range of bucket indices present
    if(nrows==0){ host_response_set((int)(long)resp,0); return 0; }
    int minb=0x7fffffff, maxb=-0x7fffffff;
    for(int i=0;i<nrows;i++){
      int ts=rd32(ser,i*8);
      int b = (ts>=0) ? (ts/w) : -(((-ts)+w-1)/w);
      if(b<minb) minb=b; if(b>maxb) maxb=b;
    }
    for(int b=minb;b<=maxb;b++){
      int cnt=0; int sum=0; int mn=0x7fffffff; int mx=-0x7fffffff;
      for(int i=0;i<nrows;i++){
        int ts=rd32(ser,i*8); int val=rd32(ser,i*8+4);
        int bb = (ts>=0) ? (ts/w) : -(((-ts)+w-1)/w);
        if(bb==b){ cnt++; sum+=val; if(val<mn) mn=val; if(val>mx) mx=val; }
      }
      if(cnt==0) continue;
      int bstart = b*w;
      rp=put_int(rp,bstart); rp=put_str(rp," count="); rp=put_int(rp,cnt);
      rp=put_str(rp," sum="); rp=put_int(rp,sum);
      rp=put_str(rp," min="); rp=put_int(rp,mn);
      rp=put_str(rp," max="); rp=put_int(rp,mx);
      rp=put_str(rp," avg="); rp=put_int(rp,sum/cnt);
      resp[rp++]='\n';
    }
    host_response_set((int)(long)resp, rp); return 0;
  }
  int rp=put_str(0,"ERR\n");
  host_response_set((int)(long)resp, rp); return 0;
}
'''

  defp compile_reactor(body_c) do
    dir = Path.join([__DIR__, "fixtures", "timescaledb"])
    File.mkdir_p!(dir)
    src = Path.join(dir, "tsdb_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.rm(src)
    File.read!(wasm)
  end

  # Independent Elixir reference for time_bucket(width) aggregation.
  defp ref_buckets(rows, w) do
    rows
    |> Enum.group_by(fn {ts, _} -> Integer.floor_div(ts, w) end)
    |> Enum.sort_by(fn {b, _} -> b end)
    |> Enum.map(fn {b, pairs} ->
      vals = Enum.map(pairs, fn {_, v} -> v end)
      sum = Enum.sum(vals)
      cnt = length(vals)

      "#{b * w} count=#{cnt} sum=#{sum} min=#{Enum.min(vals)} max=#{Enum.max(vals)} avg=#{Integer.floor_div(sum, cnt)}"
    end)
  end

  @tag :build
  @tag timeout: 360_000
  test "TimescaleDB time_bucket continuous aggregate — ingest then bucketed AVG/SUM/MIN/MAX, durable" do
    serve_id = "tsdb#{System.unique_integer([:positive])}"
    tenant = "tsdb-#{System.unique_integer([:positive])}"

    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: compile_reactor(@tsdb_c), imports: %{"env" => env}})

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

    post = fn body ->
      {:ok, {{_, status, _}, _h, b}} =
        :httpc.request(
          :post,
          {~c"http://127.0.0.1:#{port}/", [], ~c"text/plain", body},
          [],
          body_format: :binary
        )

      assert status == 200
      to_string(b)
    end

    # time-series sample: (ts seconds, value). Spread over several 10s buckets.
    rows = [
      {0, 5},
      {3, 15},
      {9, 10},
      {10, 20},
      {12, 40},
      {19, 30},
      {25, 7},
      {100, 1},
      {103, 2},
      {109, 3}
    ]

    # ingest each row over its OWN http request -> proves state persists across requests (durable KV)
    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {{ts, v}, i} ->
      assert post.("INGEST #{ts} #{v}") == "OK #{i}"
    end)

    # query time_bucket(10) continuous aggregate
    got =
      post.("BUCKET 10")
      |> String.split("\n", trim: true)

    expected = ref_buckets(rows, 10)
    assert got == expected

    # spot-check a couple buckets explicitly so the assertion is human-legible:
    # bucket 0 (ts 0..9): vals 5,15,10 -> count=3 sum=30 min=5 max=15 avg=10
    assert "0 count=3 sum=30 min=5 max=15 avg=10" in got
    # bucket 10 (ts 10..19): vals 20,40,30 -> count=3 sum=90 min=20 max=40 avg=30
    assert "10 count=3 sum=90 min=20 max=40 avg=30" in got
    # bucket 100 (ts 100..109): vals 1,2,3 -> count=3 sum=6 min=1 max=3 avg=2
    assert "100 count=3 sum=6 min=1 max=3 avg=2" in got

    # a different bucket width re-aggregates the SAME durable hypertable (no re-ingest)
    got5 = post.("BUCKET 5") |> String.split("\n", trim: true)
    assert got5 == ref_buckets(rows, 5)
    # bucket [0,5): only ts 0,3 -> vals 5,15 ; bucket [5,10): ts 9 -> val 10
    assert "0 count=2 sum=20 min=5 max=15 avg=10" in got5
    assert "5 count=1 sum=10 min=10 max=10 avg=10" in got5
  end
end
