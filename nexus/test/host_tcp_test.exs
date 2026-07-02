defmodule Nexus.HostTcpTest do
  @moduledoc """
  Layer 2: host-brokered raw TCP. A real Rust CLI (host-tcp / tcp-probe, no guest sockets) does
  connect/send/recv through washy's host_tcp_* imports to the host transport. Generic — the runtime
  tracks fd → connection ref; a caller-set :tl_sock hook owns the bytes (production = :gen_tcp,
  SSRF-guarded via Nexus.Dock.tcp_handler). Plus a deterministic Dock SSRF-block check.

  Fixture: test/fixtures/tcp-probe.wasm (compilers/rust/shims/tcp-probe).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm, as: Washy

  @fixture "test/fixtures/tcp-probe.wasm"

  setup do
    on_exit(fn ->
      Enum.each([:tl_sock, :tl_sockets, :tl_out, :tl_mem, :tl_argv, :tl_stdin, :tl_fds, :tl_nextfd], &Process.delete/1)
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

  test "a real Rust CLI does host-brokered TCP connect/send/recv (no guest sockets)", %{} = ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] tcp-probe.wasm fixture absent")
    else
      seen = self()

      Process.put(:tl_sock, fn
        {:connect, host, port} ->
          send(seen, {:connect, host, port})
          {:ok, :stub_sock}

        {:send, :stub_sock, data} ->
          send(seen, {:send, data})
          byte_size(data)

        {:recv, :stub_sock, _max} ->
          {:data, "HTTP/1.1 200 OK"}

        {:close, :stub_sock} ->
          :ok
      end)

      out = run(ctx.mod)
      assert out =~ "recv=HTTP/1.1 200 OK"
      assert out =~ "sent=18"
      # the host saw the real connect target + sent bytes the Rust program emitted
      assert_received {:connect, "example.com", 80}
      assert_received {:send, "GET / HTTP/1.0\r\n\r\n"}
    end
  end

  test "no transport wired → connect fails, the guest sees it", %{} = ctx do
    if ctx[:skip] do
      :ok
    else
      out = run(ctx.mod)
      assert out =~ "error:"
      refute out =~ "recv=HTTP"
    end
  end

  test "Dock.tcp_handler refuses an internal/loopback target (SSRF-guarded)" do
    handler = Nexus.Dock.tcp_handler()
    assert {:error, _} = handler.({:connect, "127.0.0.1", 22})
    assert {:error, _} = handler.({:connect, "169.254.169.254", 80})
  end
end
