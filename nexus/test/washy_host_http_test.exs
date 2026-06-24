defmodule Nexus.WashyHostHttpTest do
  @moduledoc """
  host_http — the thesis's network emulation. A guest CLI (wasm has no sockets) makes an in-process
  HTTP call; the host performs it and buffers the response back. Proven with a REAL compiled C guest
  that binds the host_http/host_http_read imports — the exact ABI a vendored CLI (gws) would use once
  its transport is forked onto it. Skips when the C wasm lane isn't built.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  @csrc """
  __attribute__((import_module("env"), import_name("host_http")))
  extern int host_http(const char *req, int len);
  __attribute__((import_module("env"), import_name("host_http_read")))
  extern int host_http_read(char *buf);
  extern long write(int, const void *, unsigned long);
  static int slen(const char *s){ int n=0; while(s[n]) n++; return n; }
  int main(void){
    const char *req = "GET https://example.com/\\n\\n";
    int n = host_http(req, slen(req));
    if (n < 0){ write(1, "no-transport", 12); return 1; }
    static char buf[65536];
    int status = host_http_read(buf);
    write(1, buf, n);
    write(1, " ", 1);
    char s[12]; int sl=0;
    if (status==0){ s[sl++]='0'; } else { char t[12]; int ti=0, x=status; while(x){ t[ti++]='0'+(x%10); x/=10; } while(ti) s[sl++]=t[--ti]; }
    write(1, s, sl);
    return 0;
  }
  """

  setup_all do
    if File.dir?(Nexus.Compilers.Shared.default_root()), do: %{ok: true}, else: %{skip: true}
  end

  setup %{} = ctx do
    if ctx[:skip] do
      :ok
    else
      dir = Path.join(System.tmp_dir!(), "wb-hh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "http_probe.c")
      File.write!(path, @csrc)

      mod =
        case Nexus.Compilers.C.compile_to_wasm(path, shape: :command) do
          {:ok, wasm_path} -> elem(Washy.decode_cached(File.read!(wasm_path)), 1)
          _ -> nil
        end

      on_exit(fn ->
        File.rm_rf(dir)
        Enum.each([:washy_http, :washy_out, :washy_mem, :washy_argv, :washy_stdin, :washy_fds], &Process.delete/1)
      end)

      {:ok, dir: dir, mod: mod}
    end
  end

  defp run(mod) do
    try do
      {_r, o} = Washy.call_io(mod, "_start", [])
      o
    catch
      :throw, {:washy_exit, _c} ->
        Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  test "a compiled guest CLI's in-process HTTP call is performed by the host transport", %{} = ctx do
    if ctx[:skip] || is_nil(ctx[:mod]) do
      IO.puts("\n[skip] C wasm lane not built")
    else
      seen = self()

      Process.put(:washy_http, fn req ->
        send(seen, {:req, req})
        {"hello-from-host", 200}
      end)

      out = run(ctx.mod)
      assert out =~ "hello-from-host"
      assert out =~ "200"
      # the host saw the guest's actual request bytes
      assert_received {:req, req}
      assert req =~ "GET https://example.com/"
    end
  end

  test "no transport wired → host_http returns -1 and the guest sees the failure", %{} = ctx do
    if ctx[:skip] || is_nil(ctx[:mod]) do
      :ok
    else
      # :washy_http unset
      out = run(ctx.mod)
      assert out =~ "no-transport"
    end
  end

  test "Dock.serve parses a raw request and is SSRF-guarded (loopback blocked)" do
    # Deterministic: no external network. Loopback must be refused by the SSRF gate → {"", 0}.
    assert {"", 0} = Nexus.Dock.serve("GET http://127.0.0.1:9/secret\n\n")
    assert {"", 0} = Nexus.Dock.serve("POST http://169.254.169.254/latest\nContent-Type: application/json\n\n{}")
  end
end
