defmodule Nexus.WashyHostExecTest do
  @moduledoc """
  host_exec (wb-k74l): the thesis's fork/exec emulation — a guest invokes ANOTHER program's wasm
  module, run NESTED by Washy with isolated context, output buffered back. No real fork/concurrency.
  Proven against real Rust coreutils as the program registry.
  """
  use ExUnit.Case, async: false

  alias Nexus.Washy

  setup do
    if File.exists?("kits/coreutils.wasm") do
      {:ok, cu} = Washy.decode_cached(File.read!("kits/coreutils.wasm"))
      # register coreutils as the multicall default: any argv[0] dispatches inside it
      Process.put(:washy_programs, %{default: cu})
      Process.put(:washy_vfs, %{})
      Process.put(:washy_backend, :map)
      on_exit(fn -> Enum.each([:washy_programs, :washy_vfs, :washy_backend, :washy_out, :washy_argv, :washy_stdin, :washy_fds], &Process.delete/1) end)
      {:ok, ok: true}
    else
      {:ok, skip: true}
    end
  end

  test "host_exec runs a real program (coreutils echo) nested and returns its stdout", ctx do
    if ctx[:skip] do
      IO.puts("\n[skip] coreutils.wasm absent")
    else
      assert {"hi\n", 0} = Washy.host_exec(["echo", "hi"], "")
    end
  end

  test "an unknown program returns exit 127 (command not found)", ctx do
    if ctx[:skip] do
      :ok
    else
      Process.put(:washy_programs, %{})
      assert {"", 127} = Washy.host_exec(["nope"], "")
    end
  end

  test "nesting is isolated: the parent's captured stdout + memory survive the child run", ctx do
    if ctx[:skip] do
      :ok
    else
      # simulate a parent mid-run: it has accumulated stdout and a live memory
      Process.put(:washy_out, ["parent-pre"])
      parent_mem = :atomics.new(8192, signed: false)
      :atomics.put(parent_mem, 1, 123)
      Process.put(:washy_mem, parent_mem)

      {child_out, 0} = Washy.host_exec(["echo", "child"], "")
      assert child_out == "child\n"

      # parent context fully restored — child neither clobbered our stdout nor our memory
      assert Process.get(:washy_out) == ["parent-pre"]
      assert Process.get(:washy_mem) == parent_mem
      assert :atomics.get(parent_mem, 1) == 123
    end
  end

  test "host_exec can be chained (output of one feeds the next) — buffered pipe", ctx do
    if ctx[:skip] do
      :ok
    else
      # echo a multi-line blob, then feed it as stdin to `sort`
      {blob, 0} = Washy.host_exec(["printf", "b\\na\\nc\\n"], "")
      {sorted, 0} = Washy.host_exec(["sort"], blob)
      assert sorted == "a\nb\nc\n"
    end
  end

  describe "invoke_host seam (the transpiler's path to WASI I/O)" do
    test "dispatches a host import to the same call_host the interpreter uses" do
      mem = :atomics.new(8192, signed: false)
      Process.put(:washy_mem, mem)
      on_exit(fn -> Process.delete(:washy_mem) end)

      # random_get fills guest memory with real bytes
      assert 0 = Washy.invoke_host({"wasi", "random_get", 0}, [0, 8])
      assert :atomics.get(mem, 1) != 0

      # proc_exit throws the exit signal the caller catches
      assert catch_throw(Washy.invoke_host({"wasi", "proc_exit", 0}, [5])) == {:washy_exit, 5}
    end
  end
end
