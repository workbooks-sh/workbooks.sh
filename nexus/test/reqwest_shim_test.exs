defmodule Nexus.ReqwestShimTest do
  @moduledoc """
  Layer 1 proof: an async `reqwest` + `#[tokio::main]` CLI — the shape a real vendored CLI (gws) is
  built from — compiled to wasm32-wasip1 via the reqwest SHIM (transport = host_http, tokio trimmed to
  rt/macros) RUNS on washy with its HTTP routed through the host. No sockets, no TLS, no tokio-net in
  the guest. This is "drop in a reqwest CLI, it just works" — the shim is written once, every CLI reuses it.

  Fixture: test/fixtures/reqwest-probe.wasm, built from compilers/rust/shims/reqwest-probe
  (depends on the shim's reqwest by path; in a vendored CLI the compiler patches reqwest -> the shim).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm, as: Washy

  @fixture "test/fixtures/reqwest-probe.wasm"

  setup do
    on_exit(fn ->
      Enum.each([:tl_http, :tl_out, :tl_mem, :tl_argv, :tl_stdin, :tl_fds], &Process.delete/1)
    end)

    if File.exists?(@fixture) do
      {:ok, mod} = Washy.decode_cached(File.read!(@fixture))
      {:ok, mod: mod}
    else
      {:ok, skip: true}
    end
  end

  defp run(mod) do
    try do
      {_r, o} = Washy.call_io(mod, "_start", [])
      o
    catch
      :throw, {:tl_exit, _c} ->
        Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  test "an async reqwest+tokio CLI runs on washy with HTTP via host_http", %{} = ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] reqwest-probe.wasm fixture absent")
    else
      seen = self()

      Process.put(:tl_http, fn req ->
        send(seen, {:req, req})
        {"<html>hello world</html>", 200}
      end)

      out = run(ctx.mod)
      assert out =~ "status=200"
      assert out =~ "bytes=24"
      # the host saw the request reqwest emitted — routed through the shim, not a socket
      assert_received {:req, req}
      assert req =~ "GET https://example.com/"
    end
  end
end
