defmodule Workbooks.Reclaim.SupabaseTest do
  @moduledoc """
  RECLAIM — Supabase (PostgREST REST surface) made DURABLE.

  Reproduces the run1 agent's in-sandbox proof: a sandboxed WASM reactor guest that serves the
  Supabase/PostgREST data-API essence — `/rest/v1/<table>` SELECT (GET) + INSERT (POST) — over a
  HOST-owned HTTP listener, with each table's rows persisted in durable KV (StorageBroker). We
  build the guest INLINE (Compilers.compile_c), serve it via ServeBroker.Plug + Bandit, and prove
  an insert-then-select round-trip over real HTTP, including cross-table isolation.

  Honest scope: this proves the PostgREST table REST capability (parse METHOD + table from path,
  append JSON body to a per-table JSON array, return the array). GoTrue auth, realtime WS, and
  native Postgres SQL/RLS are the broader Supabase product and are NOT emulated.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  # PostgREST-essence guest, no libc (links under crt:false). It:
  #   - reads the request "METHOD PATH\n...headers...\n\n<body>" via host_request_get
  #   - extracts the last path segment after "/rest/v1/" as the table name -> KV key "t:<table>"
  #   - GET : returns the stored JSON array (or "[]" if none)
  #   - POST: reads the existing array, splices the new JSON object before the trailing ']'
  #           (turning "[]" -> "[<obj>]" and "[a]" -> "[a,<obj>]"), persists it, returns the new array
  # All string/array work is manual (no stdlib) so it links no_std.
  @guest_c ~S"""
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);

static char req[8192];
static char key[128];
static char cur[8192];
static char out[16384];
static char body[8192];

static int slen(const char* s){ int n=0; while(s[n]) n++; return n; }
static int eq(const char* a, const char* b, int n){ for(int i=0;i<n;i++){ if(a[i]!=b[i]) return 0; } return 1; }

__attribute__((export_name("handle"))) int handle(void){
  int rn = host_request_get((int)(long)req, sizeof(req)); if(rn<0) rn=0;

  // ---- parse method (up to first space) ----
  int is_post = (rn>=4 && eq(req,"POST",4));

  // ---- find the path: chars after first space up to '\n' or next space ----
  int i=0; while(i<rn && req[i]!=' ') i++;   // skip method
  i++;                                       // skip the space
  int ps=i;
  while(i<rn && req[i]!=' ' && req[i]!='\n') i++;
  int pe=i;                                  // path = req[ps..pe)

  // ---- table = last '/'-segment of the path (strip any ?query) ----
  int q=ps; while(q<pe && req[q]!='?') q++;  // q = end of path-without-query
  int seg=ps;
  for(int j=ps;j<q;j++){ if(req[j]=='/') seg=j+1; }
  int tl = q-seg; if(tl<0) tl=0; if(tl>100) tl=100;

  // ---- build KV key "t:<table>" ----
  key[0]='t'; key[1]=':'; int kl=2;
  for(int j=0;j<tl;j++) key[kl++]=req[seg+j];

  // ---- load current array (default "[]") ----
  int cl = host_kv_get((int)(long)key, kl, (int)(long)cur, sizeof(cur));
  if(cl<=0){ cur[0]='['; cur[1]=']'; cl=2; }

  if(is_post){
    // ---- extract request body: bytes after the blank line "\n\n" ----
    int bs=-1;
    for(int j=0;j+1<rn;j++){ if(req[j]=='\n' && req[j+1]=='\n'){ bs=j+2; break; } }
    int bl=0;
    if(bs>=0){ for(int j=bs;j<rn;j++) body[bl++]=req[j]; }
    // trim trailing whitespace/newlines on the body
    while(bl>0 && (body[bl-1]=='\n'||body[bl-1]=='\r'||body[bl-1]==' ')) bl--;

    // ---- splice: copy cur[0..cl-1) (everything before the trailing ']'),
    //      add "," if the array was non-empty, then body, then "]" ----
    int has_items = (cl>2);   // "[]" is empty; anything longer already holds >=1 item
    int o=0;
    for(int j=0;j<cl-1;j++) out[o++]=cur[j];   // drop the closing ']'
    if(has_items) out[o++]=',';
    for(int j=0;j<bl;j++) out[o++]=body[j];
    out[o++]=']';

    host_kv_put((int)(long)key, kl, (int)(long)out, o);
    const char* st="200\nContent-Type: application/json\n\n";
    int sl=slen(st);
    // prepend the status head then the JSON array, all in one response buffer reuse via cur
    // (write head + body sequentially into 'cur' which is free now)
    int p=0; for(int j=0;j<sl;j++) cur[p++]=st[j]; for(int j=0;j<o;j++) cur[p++]=out[j];
    host_response_set((int)(long)cur, p);
    return 0;
  } else {
    // GET: return the stored array
    const char* st="200\nContent-Type: application/json\n\n";
    int sl=slen(st);
    int p=0; for(int j=0;j<sl;j++) out[p++]=st[j]; for(int j=0;j<cl;j++) out[p++]=cur[j];
    host_response_set((int)(long)out, p);
    return 0;
  }
}
"""

  setup_all do
    src = Path.join(System.tmp_dir!(), "supabase_reclaim_#{System.unique_integer([:positive])}.c")
    File.write!(src, @guest_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    %{wasm: File.read!(wasm)}
  end

  defp serve(wasm, tenant) do
    serve_id = "supabase-#{System.unique_integer([:positive])}"
    # network profile grants the KV (vfs) cap; the tenant scopes the durable namespace.
    dock = RustDock.imports(profile: :network, tenant: tenant)["env"]
    env = Map.merge(dock, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: wasm, imports: %{"env" => env}})
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
    port
  end

  defp req(port, method, path, body) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    request =
      case method do
        :get -> {url, []}
        :post -> {url, [], ~c"application/json", body}
      end

    {:ok, {{_, s, _}, _, b}} =
      :httpc.request(method, request, [], body_format: :binary)

    {s, to_string(b)}
  end

  @tag :build
  @tag timeout: 600_000
  test "PostgREST surface: insert-then-select round-trips, persisted in durable KV, table-isolated",
       %{wasm: wasm} do
    tenant = "sb-#{System.unique_integer([:positive])}"
    port = serve(wasm, tenant)

    # empty table -> "[]"
    assert {200, "[]"} = req(port, :get, "/rest/v1/users", "")

    # INSERT a row -> returned array now holds it
    {status1, after1} = req(port, :post, "/rest/v1/users", ~s({"id":1,"name":"ada"}))
    assert status1 == 200
    assert after1 == ~s([{"id":1,"name":"ada"}])

    # second INSERT appends (comma-joined JSON array)
    {200, after2} = req(port, :post, "/rest/v1/users", ~s({"id":2,"name":"bob"}))
    assert after2 == ~s([{"id":1,"name":"ada"},{"id":2,"name":"bob"}])

    # SELECT returns the persisted array
    assert {200, ^after2} = req(port, :get, "/rest/v1/users", "")

    # TABLE ISOLATION: a different table is independent (own KV key)
    assert {200, "[]"} = req(port, :get, "/rest/v1/orders", "")
    {200, ord} = req(port, :post, "/rest/v1/orders", ~s({"sku":"x"}))
    assert ord == ~s([{"sku":"x"}])
    # users still intact
    assert {200, ^after2} = req(port, :get, "/rest/v1/users", "")
  end
end
