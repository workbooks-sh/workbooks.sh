defmodule Workbooks.BrokeredAppTest do
  @moduledoc """
  The app-host PLATFORM: many sandboxed apps over one router, each persisted (durable KV scoped to its tenant)
  + isolated + grant-scoped. Proves the "deploy target" productization — define -> served + persisted + isolated.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{BrokeredApp, Compilers}

  defp compile_reactor(body_c) do
    src = Path.join(System.tmp_dir!(), "app_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.read!(wasm)
  end

  # a stateful counter app: per request, read the durable KV key "n", increment, persist, return "count=<n>".
  # No libc — manual int parse/format so it links under crt:false.
  defp counter_bytes do
    compile_reactor(~S"""
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);
__attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
static char req[64]; static char cur[32]; static char nbuf[32]; static char resp[40];
static long parse(const char* s, int n){ long v=0; for(int i=0;i<n;i++){ if(s[i]<'0'||s[i]>'9') break; v=v*10+(s[i]-'0'); } return v; }
static int fmt(long v, char* s){ char t[24]; int i=0; if(v==0){ s[0]='0'; return 1; } while(v>0){ t[i++]='0'+(v%10); v/=10; } for(int j=0;j<i;j++) s[j]=t[i-1-j]; return i; }
__attribute__((export_name("handle"))) int handle(void){
  host_request_get((int)(long)req, 64);
  int n = host_kv_get((int)(long)"n", 1, (int)(long)cur, 32);
  long v = (n>0) ? parse(cur, n) : 0;
  v++;
  int nl = fmt(v, nbuf);
  host_kv_put((int)(long)"n", 1, (int)(long)nbuf, nl);
  const char* p = "count="; int k=0; while(p[k]){ resp[k]=p[k]; k++; }
  for(int i=0;i<nl;i++) resp[k+i]=nbuf[i];
  host_response_set((int)(long)resp, k+nl); return 0;
}
""")
  end

  defp router_port(apps) do
    Enum.each(apps, fn {name, bytes, opts} -> {:ok, _} = BrokeredApp.define(name, bytes, opts) end)
    on_exit(fn -> Enum.each(apps, fn {name, _, _} -> BrokeredApp.stop(name) end) end)
    port = 46_000 + rem(System.unique_integer([:positive]), 3_000)

    {:ok, srv} =
      Bandit.start_link(plug: Workbooks.BrokeredApp.Router, scheme: :http, ip: {127, 0, 0, 1}, port: port)

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)
    port
  end

  defp get(port, path) do
    {:ok, {{_, s, _}, _, b}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", []}, [], body_format: :binary)

    {s, to_string(b)}
  end

  @tag :build
  @tag timeout: 300_000
  test "ROUTING + PERSISTENCE + ISOLATION — many apps, one router, each persisted to its own durable KV" do
    cbytes = counter_bytes()
    # two independent counters (distinct tenants) + the same router
    port =
      router_port([
        {"counterA", cbytes, [route: "/a", tenant: "appA-#{System.unique_integer([:positive])}"]},
        {"counterB", cbytes, [route: "/b", tenant: "appB-#{System.unique_integer([:positive])}"]}
      ])

    # ROUTING: /a -> counterA, /b -> counterB; unknown -> 404
    assert {200, "count=1"} = get(port, "/a")
    assert {200, "count=2"} = get(port, "/a")
    # ISOLATION: counterB has its own durable namespace -> starts fresh at 1 despite A being at 2
    assert {200, "count=1"} = get(port, "/b")
    assert {404, _} = get(port, "/nope")

    # PERSISTENCE across an app-instance RESTART: stop+redefine counterA (new wasm instance, SAME tenant) ->
    # the durable KV survives, so the count CONTINUES (the instance is ephemeral; the data is not).
    appA = BrokeredApp.lookup("counterA")
    :ok = BrokeredApp.stop("counterA")
    assert {404, _} = get(port, "/a")
    {:ok, _} = BrokeredApp.define("counterA", cbytes, route: "/a", tenant: appA.tenant)
    on_exit(fn -> BrokeredApp.stop("counterA") end)
    assert {200, "count=3"} = get(port, "/a")
  end

  test "define/lookup/stop lifecycle + longest-prefix routing (hermetic, no server)" do
    b = counter_bytes()
    {:ok, _} = BrokeredApp.define("svc", b, route: "/svc")
    {:ok, _} = BrokeredApp.define("svcdeep", b, route: "/svc/deep")
    on_exit(fn -> BrokeredApp.stop("svc"); BrokeredApp.stop("svcdeep") end)

    assert BrokeredApp.lookup("svc")
    assert "svc" in Enum.map(BrokeredApp.list(), & &1.name)
    # longest-prefix wins: /svc/deep/x -> svcdeep, /svc/x -> svc
    assert BrokeredApp.route_for("/svc/deep/x").name == "svcdeep"
    assert BrokeredApp.route_for("/svc/x").name == "svc"
    assert BrokeredApp.route_for("/other") == nil

    :ok = BrokeredApp.stop("svc")
    refute BrokeredApp.lookup("svc")
    assert Workbooks.Revocation.revoked?("svc")
  end
end
