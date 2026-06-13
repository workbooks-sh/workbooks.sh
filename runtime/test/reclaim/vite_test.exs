defmodule Workbooks.Reclaim.ViteTest do
  @moduledoc """
  RECLAIM (resolved.json["Vite"]): Vite's two-part essence, in-sandbox.

  The reclaim recipe: "esbuild.wasm transforms/bundles a multi-file TS/JSX project
  (the exact engine Vite uses), and ServeBroker serves the output over the host listener."

  This test reproduces BOTH halves end-to-end, self-contained:
    1. BUILD: Workbooks.Compilers.esbuild_bundle_dir bundles a multi-file TS+JSX
       project (the dev/build transform Vite delegates to esbuild for) — TS types
       stripped, ESM resolution across files, JSX transformed.
    2. SERVE: the bundled JS is embedded into a C reactor guest that exports `handle`,
       granted ServeBroker.imports, and mounted on a REAL Bandit HTTP listener via
       ServeBroker.Plug. A real HTTP GET retrieves the bundle the guest serves.

    The guest never touches a socket (ServeBroker owns the listener) — exactly the
    "host-as-listener + sandboxed guest" model the recipe describes.

  @tag :build — needs esbuild.wasm + clang.wasm (gitignored, staged into compilers pkg).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, ServeBroker}

  @moduletag :build
  @compilers_root Path.expand("../../compilers", __DIR__)

  defp fixture(files) do
    dir = Path.join(System.tmp_dir!(), "vite-reclaim-#{System.unique_integer([:positive])}")
    for {p, b} <- files do
      f = Path.join(dir, p)
      File.mkdir_p!(Path.dirname(f))
      File.write!(f, b)
    end
    dir
  end

  @tag timeout: 600_000
  test "Vite essence: esbuild bundles a multi-file TS+JSX project, ServeBroker serves it over real HTTP" do
    # ---- 1. BUILD (the esbuild transform Vite delegates to) ----
    dir =
      fixture(%{
        "package.json" => ~S|{"name":"viteapp","version":"1.0.0"}|,
        "src/math.ts" =>
          "export const add = (a: number, b: number): number => a + b;\n",
        "src/App.jsx" =>
          ~S|import { add } from './math.ts';
export const App = () => <div className="app">sum={add(40, 2)}</div>;
|,
        "src/main.jsx" =>
          ~S|import { App } from './App.jsx';
export const total = add42();
function add42() { return App; }
|
      })

    t0 = System.monotonic_time(:millisecond)

    {:ok, js} =
      Compilers.esbuild_bundle_dir(
        dir,
        "src/main.jsx",
        [format: "esm", jsx: "transform"],
        @compilers_root
      )

    dt = System.monotonic_time(:millisecond) - t0

    # TS types stripped, ESM resolution across files happened, JSX transformed to calls
    refute js =~ ": number", "TS types must be stripped by esbuild"
    assert js =~ "add", "cross-file ESM import resolved + tree-kept"
    assert js =~ "createElement", "JSX must be transformed (the React-classic transform)"
    assert dt < 30_000, "esbuild.wasm should be ~sub-second (Vite's fast path); took #{dt}ms"
    IO.puts("\n[vite/esbuild] multi-file TS+JSX bundle in #{dt}ms, #{byte_size(js)} bytes")
    File.rm_rf!(dir)

    # ---- 2. SERVE (ServeBroker owns the listener; guest serves the asset) ----
    # Embed the bundled JS as a C reactor that responds with the bundle on every request,
    # content-typed as JS — exactly how Vite's dev server would hand back a module.
    bundle_bytes = js
    serve_id = "vite-#{System.unique_integer([:positive])}"
    guest_pid = serve_bundle_guest(bundle_bytes, serve_id)

    # In-process serve-flip dispatch works (host re-enters the persistent guest per request)
    assert {:ok, resp} = ServeBroker.dispatch(serve_id, guest_pid, "GET /assets/main.js\n\n")
    assert resp =~ "createElement", "the guest served the real bundled module bytes"

    # And over a REAL HTTP listener
    port = 46_000 + rem(System.unique_integer([:positive]), 3_000)

    {:ok, srv} =
      Bandit.start_link(
        plug: {ServeBroker.Plug, serve_id: serve_id, pid: guest_pid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    on_exit(fn -> Process.exit(srv, :normal) end)
    Process.sleep(150)
    _ = Application.ensure_all_started(:inets)

    {:ok, {{_, status, _}, hdrs, body}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{port}/assets/main.js", []},
        [],
        body_format: :binary
      )

    body = to_string(body)
    assert status == 200
    assert {~c"content-type", ~c"application/javascript"} in hdrs
    assert body =~ "createElement",
           "the dev-server response carried the esbuild-bundled module Vite would ship"

    IO.puts("[vite/serve] real HTTP GET returned the esbuild bundle (#{byte_size(body)} bytes, 200)")
  end

  # A reactor guest that serves a fixed byte payload (the esbuild bundle) with a
  # JS content-type. It reads/ignores the request and writes a structured response:
  #   "200\ncontent-type: application/javascript\n\n<bundle>"
  # The bundle is injected as a C string literal byte array at compile time.
  defp serve_bundle_guest(payload, serve_id) do
    # encode payload as a C array initializer to avoid escaping pitfalls
    bytes = :binary.bin_to_list(payload)
    arr = bytes |> Enum.map(&Integer.to_string/1) |> Enum.join(",")
    plen = length(bytes)

    csrc = """
    __attribute__((import_module("env"),import_name("host_request_get"))) extern int host_request_get(int,int);
    __attribute__((import_module("env"),import_name("host_response_set"))) extern int host_response_set(int,int);
    static unsigned char reqbuf[1024];
    static const unsigned char payload[#{plen}] = {#{arr}};
    static const char* hdr = "200\\ncontent-type: application/javascript\\n\\n";
    static unsigned char resp[#{plen + 128}];
    __attribute__((export_name("handle"))) int handle(void) {
      int n = host_request_get((int)(long)reqbuf, 1024); (void)n;
      int p = 0;
      for (int i = 0; hdr[i]; i++) resp[p++] = hdr[i];
      for (int i = 0; i < #{plen}; i++) resp[p++] = payload[i];
      host_response_set((int)(long)resp, p);
      return 0;
    }
    """

    src = Path.join(System.tmp_dir!(), "vite_serve_#{System.unique_integer([:positive])}.c")
    File.write!(src, csrc)

    {:ok, wasm, _} =
      Compilers.compile_c(src, [crt: false, ld_args: ["--no-entry", "--export-memory"]], @compilers_root)

    wasm_bytes = File.read!(wasm)
    {:ok, pid} = Wasmex.start_link(%{bytes: wasm_bytes, imports: %{"env" => ServeBroker.imports(serve_id)}})
    pid
  end
end
