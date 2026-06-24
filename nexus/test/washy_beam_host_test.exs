defmodule Nexus.WashyBeamHostTest do
  @moduledoc """
  The `Beam.*` JS↔OTP interop HOST SEAM (`lib/washy.ex` `call_host` clauses). These bridge a guest's
  `Beam` global (wasm host imports) to `Nexus.Washy.Actor`, reading/writing guest memory. They're inert
  until `qjs-run.wasm` is rebuilt to import them, so we exercise them directly via `invoke_host` with a
  real packed memory — proving the memory→Actor→memory round-trip.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy
  alias Nexus.Washy.Actor

  setup do
    {Registry, keys: :unique, name: Nexus.Washy.Actor.Registry} |> maybe_start()
    {DynamicSupervisor, strategy: :one_for_one, name: Nexus.Washy.Actor.Supervisor} |> maybe_start()
    # a 1-page packed memory, installed where the host clauses read it (`wmem/0` → :washy_mem).
    mem = :atomics.new(8192, signed: false)
    Process.put(:washy_mem, mem)
    Process.put(:washy_mem_pages, 1)
    {:ok, mem: mem}
  end

  defp maybe_start(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, {{:already_started, _}, _}} -> :ok
    end
  end

  test "beam_call routes name+args from guest memory to an Elixir handler and writes the JSON reply back", %{mem: mem} do
    {:ok, _} = Actor.beam_spawn(fn [a, b], _ -> {a + b, nil} end, name: "adder")

    # poke the call args into guest memory, as the JS `Beam.call` host import would have.
    name = "adder"
    args = Jason.encode!([3, 4])
    name_ptr = 100
    args_ptr = 200
    out_ptr = 300
    Washy.write_bytes(mem, name_ptr, name)
    Washy.write_bytes(mem, args_ptr, args)

    reply_len =
      Washy.invoke_host(
        {"beam", "beam_call", nil},
        [name_ptr, byte_size(name), args_ptr, byte_size(args), out_ptr]
      )

    assert reply_len > 0
    assert Washy.read_bytes(mem, out_ptr, reply_len) == Jason.encode!(7)
  end

  test "beam_self writes the guest's handle into memory", %{mem: mem} do
    Process.put(:washy_actor_self, self())
    out_ptr = 400
    len = Washy.invoke_host({"beam", "beam_self", nil}, [out_ptr])
    assert len > 0
    handle = Washy.read_bytes(mem, out_ptr, len)
    # the handle is an encoded pid that decodes back to self()
    assert :erlang.list_to_pid(to_charlist(handle)) == self()
  end

  test "beam_send to a malformed handle returns -1 (never raises)", %{mem: mem} do
    msg = Jason.encode!(%{"x" => 1})
    Washy.write_bytes(mem, 200, msg)

    # a malformed handle string must be safe (list_to_pid would raise — guarded → -1)
    bad = "not-a-pid"
    Washy.write_bytes(mem, 100, bad)
    assert -1 == Washy.invoke_host({"beam", "beam_send", nil}, [100, byte_size(bad), 200, byte_size(msg)])
  end

  test "beam_send to a live spawned actor delivers (returns 0)", %{mem: mem} do
    test = self()
    {:ok, pid} = Actor.beam_spawn(fn m, _ -> send(test, {:got, m}); {nil, nil} end, name: "sink")
    handle = pid |> :erlang.pid_to_list() |> to_string()
    msg = Jason.encode!(%{"hi" => 1})
    Washy.write_bytes(mem, 100, handle)
    Washy.write_bytes(mem, 200, msg)
    assert 0 == Washy.invoke_host({"beam", "beam_send", nil}, [100, byte_size(handle), 200, byte_size(msg)])
    assert_receive {:got, %{"hi" => 1}}, 1000
  end

  test "beam_recv writes the stashed inbox JSON (null when empty)", %{mem: mem} do
    out_ptr = 500
    len = Washy.invoke_host({"beam", "beam_recv", nil}, [out_ptr])
    assert Washy.read_bytes(mem, out_ptr, len) == "null"

    Process.put(:washy_beam_inbox, Jason.encode!(%{"hello" => "world"}))
    len2 = Washy.invoke_host({"beam", "beam_recv", nil}, [out_ptr])
    assert Jason.decode!(Washy.read_bytes(mem, out_ptr, len2)) == %{"hello" => "world"}
  end
end
