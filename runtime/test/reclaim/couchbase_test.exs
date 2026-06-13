defmodule Workbooks.Reclaim.CouchbaseTest do
  @moduledoc """
  RECLAIM (Couchbase): durable proof of the core data-node document-KV op.

  Couchbase as a clustered DB is off-the-table. What the run1 agent proved LIVE is the
  essence of a Couchbase data node: a serve-flip reactor guest speaking a memcached-style
  binary document protocol (SET key/val, GET key) backed by the durable per-tenant KV
  broker — with cross-instance durability (write on one guest instance, read it back on a
  freshly-started SECOND instance of the same tenant).

  This test builds everything itself: it compiles the reactor C inline, composes
  RustDock.imports (durable kv) + ServeBroker.imports into one env, dispatches the binary
  protocol through ServeBroker, and proves both round-trip and cross-instance durability.

  NOT reproduced (and not claimed): N1QL/SQL planner, clustering, replication. Only the
  data-node document KV op.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  # A memcached-style binary document protocol reactor:
  #   request framing: op byte, then
  #     'S' = SET : klen(1) key vlen(1) val  -> reply "OK"
  #     'G' = GET : klen(1) key              -> reply value bytes (or "NF" if missing)
  #   persistence via the durable RustDock kv broker (host_kv_put / host_kv_get).
  @reactor_c ~S"""
  __attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
  __attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
  __attribute__((import_module("env"),import_name("host_kv_put"))) extern int host_kv_put(int,int,int,int);
  __attribute__((import_module("env"),import_name("host_kv_get"))) extern int host_kv_get(int,int,int,int);
  static unsigned char req[512];
  static unsigned char key[256];
  static unsigned char val[256];
  static unsigned char resp[256];
  __attribute__((export_name("handle"))) int handle(void) {
    int n = host_request_get((int)(long)req, 512); if(n<0)n=0; if(n>512)n=512;
    if (n < 1) { resp[0]='E'; resp[1]='R'; host_response_set((int)(long)resp,2); return 0; }
    unsigned char op = req[0];
    int p = 1;
    if (op == 'S') {
      int klen = req[p++]; for (int i=0;i<klen;i++) key[i]=req[p++];
      int vlen = req[p++]; for (int i=0;i<vlen;i++) val[i]=req[p++];
      int r = host_kv_put((int)(long)key, klen, (int)(long)val, vlen);
      if (r==0){resp[0]='O';resp[1]='K';host_response_set((int)(long)resp,2);}
      else {resp[0]='E';resp[1]='R';host_response_set((int)(long)resp,2);}
      return 0;
    } else if (op == 'G') {
      int klen = req[p++]; for (int i=0;i<klen;i++) key[i]=req[p++];
      int g = host_kv_get((int)(long)key, klen, (int)(long)resp, 256);
      if (g > 0) { host_response_set((int)(long)resp, g); }
      else { resp[0]='N'; resp[1]='F'; host_response_set((int)(long)resp,2); }
      return 0;
    }
    resp[0]='E'; resp[1]='R'; host_response_set((int)(long)resp,2);
    return 0;
  }
  """

  defp compile_reactor do
    src = Path.join(System.tmp_dir!(), "couchbase_node_#{System.unique_integer([:positive])}.c")
    File.write!(src, @reactor_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.read!(wasm)
  end

  defp start_node(bytes, serve_id, tenant) do
    dock_env = RustDock.imports(profile: :minimal, tenant: tenant)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: bytes, imports: %{"env" => env}})
    pid
  end

  # SET frame: 'S' klen key vlen val
  defp set_frame(key, val),
    do: <<?S, byte_size(key), key::binary, byte_size(val), val::binary>>

  # GET frame: 'G' klen key
  defp get_frame(key), do: <<?G, byte_size(key), key::binary>>

  @tag :build
  @tag timeout: 300_000
  test "data-node document KV: SET/GET round-trips AND persists across a fresh guest instance (durable)" do
    bytes = compile_reactor()
    tenant = "cb-#{System.unique_integer([:positive])}"

    # --- instance 1 ---
    sid1 = "cb1-#{System.unique_integer([:positive])}"
    node1 = start_node(bytes, sid1, tenant)

    # GET on a missing key -> NF
    assert {:ok, "NF"} = ServeBroker.dispatch(sid1, node1, get_frame("doc:1"))

    # SET two documents
    assert {:ok, "OK"} = ServeBroker.dispatch(sid1, node1, set_frame("doc:1", "hello-couchbase"))
    assert {:ok, "OK"} = ServeBroker.dispatch(sid1, node1, set_frame("doc:2", "second-value"))

    # GET them back on the SAME instance (round-trip)
    assert {:ok, "hello-couchbase"} = ServeBroker.dispatch(sid1, node1, get_frame("doc:1"))
    assert {:ok, "second-value"} = ServeBroker.dispatch(sid1, node1, get_frame("doc:2"))

    # --- instance 2 (a freshly-started guest, SAME tenant) ---
    # This is the durability claim: the documents persisted through the host's per-tenant
    # KV broker, so a brand-new data-node instance reads them back without instance-1 state.
    sid2 = "cb2-#{System.unique_integer([:positive])}"
    node2 = start_node(bytes, sid2, tenant)

    assert {:ok, "hello-couchbase"} = ServeBroker.dispatch(sid2, node2, get_frame("doc:1")),
           "cross-instance durability failed: doc:1 not readable from a fresh guest"

    assert {:ok, "second-value"} = ServeBroker.dispatch(sid2, node2, get_frame("doc:2"))

    # --- tenant isolation: a DIFFERENT tenant must NOT see these documents ---
    other_tenant = "cb-other-#{System.unique_integer([:positive])}"
    sid3 = "cb3-#{System.unique_integer([:positive])}"
    node3 = start_node(bytes, sid3, other_tenant)
    assert {:ok, "NF"} = ServeBroker.dispatch(sid3, node3, get_frame("doc:1")),
           "tenant isolation failed: another tenant could read this tenant's documents"
  end
end
