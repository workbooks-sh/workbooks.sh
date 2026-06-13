defmodule Workbooks.BrokerTransportCTest do
  @moduledoc """
  Proves the brokered transport is LANGUAGE-AGNOSTIC, not Python-specific: a standard C program — compiled to
  wasm in-sandbox (clang.wasm, zero native toolchain) — gets SSRF-safe brokered HTTP by speaking the SAME
  request/response file protocol over a preopened dir, serviced by the SAME host watcher (PyNet.with_broker /
  run_wasm). The guest has no socket; the host does the network, fully mediated. This is the generalization of
  the seam to standard WASI tools (keystone goal 2) via the file-protocol transport.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PyNet}

  # A self-contained C HTTP client over the broker file protocol: write the request, poll for the response,
  # report whether the host serviced it. No JSON/base64 lib — it writes the request with sprintf and checks the
  # response with strstr (enough to prove the round-trip + the SSRF verdict).
  @client ~S"""
  #include <stdio.h>
  #include <string.h>
  #include <unistd.h>

  int main(int argc, char **argv) {
      const char *url = argc > 1 ? argv[1] : "http://example.com/";
      FILE *f = fopen("/b/req.json", "w");
      if (!f) { printf("NOOPEN\n"); return 2; }
      fprintf(f, "{\"method\":\"GET\",\"url\":\"%s\"}", url);
      fclose(f);
      f = fopen("/b/req.ready", "w"); fputc('1', f); fclose(f);

      static char buf[16384];
      for (int i = 0; i < 600; i++) {
          FILE *r = fopen("/b/resp.ready", "r");
          if (r) {
              fclose(r);
              FILE *rj = fopen("/b/resp.json", "r");
              size_t n = fread(buf, 1, sizeof(buf) - 1, rj);
              buf[n] = 0; fclose(rj);
              if (strstr(buf, "\"ok\":true")) { printf("BROKERED_OK\n"); return 0; }
              printf("BROKERED_DENIED\n"); return 1;
          }
          usleep(20000);
      }
      printf("TIMEOUT\n");
      return 3;
  }
  """

  setup_all do
    src = Path.join(System.tmp_dir!(), "cbroker_#{System.unique_integer([:positive])}.c")
    File.write!(src, @client)
    on_exit(fn -> File.rm(src) end)

    case Compilers.compile_c(src) do
      {:ok, wasm, _} ->
        on_exit(fn -> File.rm(wasm) end)
        {:ok, wasm: wasm}

      {:error, reason} ->
        flunk("compile_c failed for the C broker client: #{inspect(reason) |> String.slice(0, 200)}")
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 600_000
  test "a C tool fetches a public URL through the brokered transport (no guest socket)", %{wasm: wasm} do
    assert {:ok, out, 0} = PyNet.run_wasm(wasm, "", ["http://example.com/"])
    assert out =~ "BROKERED_OK"
  end

  @tag :build
  @tag timeout: 600_000
  test "RED-TEAM — a C tool CANNOT reach an internal target through the transport (host-mediated)", %{wasm: wasm} do
    # the host re-validates the URL; the C guest is denied cloud-metadata regardless of what it writes.
    assert {:ok, out, status} = PyNet.run_wasm(wasm, "", ["http://169.254.169.254/latest/meta-data/"])
    assert out =~ "BROKERED_DENIED"
    assert status != 0
  end
end
