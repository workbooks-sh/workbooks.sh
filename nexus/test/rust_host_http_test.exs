defmodule Nexus.RustHostHttpTest do
  @moduledoc """
  Layer 1 foundation: a REAL Rust CLI (compiled to wasm32-wasip1, no sockets/TLS/tokio — links only the
  `host-http` shim crate) reaches the network through washy's `host_http` import. Proves the guest-side
  path every vendored reqwest CLI will reuse once its transport is patched onto host_http.

  Fixture: test/fixtures/host-http-probe.wasm, built from compilers/rust/shims/host-http-probe
  (`cargo build --target wasm32-wasip1 --release`). Source is tracked; the wasm is its build artifact.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm, as: Washy

  @fixture "test/fixtures/host-http-probe.wasm"

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

  test "a real Rust CLI makes a host-brokered HTTP call (no guest sockets)", %{} = ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] host-http-probe.wasm fixture absent")
    else
      seen = self()

      Process.put(:tl_http, fn req ->
        send(seen, {:req, req})
        {"<html>hello</html>", 200}
      end)

      out = run(ctx.mod)
      assert out =~ "status=200"
      assert out =~ "bytes=18"
      # the host saw the real request the Rust program emitted via the shim crate
      assert_received {:req, req}
      assert req =~ "GET https://example.com/"
    end
  end

  test "without a transport the Rust CLI sees the failure (ungranted run)", %{} = ctx do
    if ctx[:skip] do
      :ok
    else
      # :tl_http unset → host_http returns -1 → the probe prints an error and exits non-zero
      out = run(ctx.mod)
      refute out =~ "status=200"
    end
  end
end
