defmodule Workbooks.BrokerAppHostTest do
  @moduledoc """
  Stone 5 — the APP-HOST capstone: the sandbox as a real deploy target. A single sandboxed wasm guest composes
  TWO brokered capabilities into a complete web application — INBOUND (host-as-listener -> guest handler via
  ServeBroker) and OUTBOUND (brokered, SSRF-mediated egress via host_http_get). This is the BFF / API-gateway
  pattern: receive a request, fetch from an upstream, return the result — entirely sandboxed, the host doing
  both privileged ops. And the egress a serving guest makes is held to the SAME SSRF cadence as any other.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock, ServeBroker}

  defp compile_reactor(body_c) do
    src = Path.join(System.tmp_dir!(), "apphost_#{System.unique_integer([:positive])}.c")
    File.write!(src, body_c)
    {:ok, wasm, _} = Compilers.compile_c(src, crt: false, ld_args: ["--no-entry", "--export-memory"])
    File.read!(wasm)
  end

  # a BFF guest: per request, fetch `url` through the brokered egress and return the body (or UPSTREAM_DENIED).
  defp bff_bytes(url) do
    compile_reactor(~s|
__attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
__attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
__attribute__((import_module("env"),import_name("host_http_get"))) extern int host_http_get(int,int,int,int);
static unsigned char req[512]; static unsigned char resp[65536];
static const char url[] = "#{url}";
__attribute__((export_name("handle"))) int handle(void) {
  int rn = host_request_get((int)(long)req, 512); if (rn<0) rn=0;
  int n = host_http_get((int)(long)url, sizeof(url)-1, (int)(long)resp, 65536);
  if (n < 0) { const char e[]="UPSTREAM_DENIED"; host_response_set((int)(long)e, 15); return 0; }
  host_response_set((int)(long)resp, n); return 0;
}|)
  end

  defp serve(bytes, serve_id) do
    dock_env = RustDock.imports(profile: :network)["env"]
    env = Map.merge(dock_env, ServeBroker.imports(serve_id))
    {:ok, pid} = Wasmex.start_link(%{bytes: bytes, imports: %{"env" => env}})
    port = 45_000 + rem(System.unique_integer([:positive]), 4_000)

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

  defp get(port, path) do
    {:ok, {{_, s, _}, _, b}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", []}, [], body_format: :binary)

    {s, to_string(b)}
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 600_000
  test "APP-HOST — a sandboxed guest serves HTTP by fetching an upstream through brokered egress (BFF)" do
    serve_id = "bff#{System.unique_integer([:positive])}"
    port = serve(bff_bytes("http://example.com/"), serve_id)

    {status, body} = get(port, "/")
    assert status == 200
    # the guest received the inbound request, fetched example.com via brokered (SSRF-safe) egress, and returned
    # it — a complete brokered web app: inbound + outbound, both host-brokered, guest fully sandboxed.
    assert body =~ "Example Domain"
  end

  @tag :build
  @tag timeout: 600_000
  test "RED-TEAM — a serving guest's egress is SSRF-mediated: it CANNOT reach cloud metadata" do
    serve_id = "bffx#{System.unique_integer([:positive])}"
    port = serve(bff_bytes("http://169.254.169.254/latest/meta-data/"), serve_id)

    {status, body} = get(port, "/")
    assert status == 200
    # the guest tried to fetch the metadata IP through its egress; NetGuard denied it -> host_http_get returned
    # -1 -> the guest emits UPSTREAM_DENIED. A serving app can't be tricked into an SSRF either.
    assert body =~ "UPSTREAM_DENIED"
    refute body =~ "ami-id"
    refute body =~ "instance-id"
  end
end
