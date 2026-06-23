defmodule Nexus.WashyValidateTest do
  @moduledoc """
  Phase C (wb-6tgv): structural validation rejects malformed untrusted modules cleanly
  (`{:error, {:invalid, _}}`) before they run, instead of crashing mid-execution on an out-of-range
  index. Valid modules pass unchanged; the sandbox validates by default.
  """
  use ExUnit.Case, async: true

  alias Nexus.Washy
  alias Nexus.Washy.{Validate, Sandbox}

  # valid: func0 add(i32,i32)->i32 ; func1 dbl(i32)->i32 = add(x,x)
  @valid <<0, 97, 115, 109, 1, 0, 0, 0, 1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127,
           3, 3, 2, 0, 1, 7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 100, 98, 108, 0, 1,
           10, 18, 2, 7, 0, 32, 0, 32, 1, 106, 11, 8, 0, 32, 0, 32, 0, 16, 0, 11>>

  test "a valid module passes validation" do
    {:ok, m} = Washy.decode(@valid)
    assert Validate.validate(m) == :ok
  end

  test "decode_validated returns the module for valid input" do
    assert {:ok, %Washy{}} = Validate.decode_validated(@valid)
  end

  test "call to an out-of-range function index is rejected" do
    # ()->i32 "f" body: call 99 (no such function)
    m = mod(<<0, 0x10, 99, 0x0B>>)
    assert {:error, {:invalid, {:call_index, 99, _}}} = Validate.validate(m)
  end

  test "local.get past the frame is rejected" do
    # f has 0 params + 0 locals; local.get 5 is out of range
    m = mod(<<0, 0x20, 5, 0x0B>>)
    assert {:error, {:invalid, {:local_get, 5, _}}} = Validate.validate(m)
  end

  test "global.get of a non-existent global is rejected" do
    m = mod(<<0, 0x23, 0, 0x0B>>)
    assert {:error, {:invalid, {:global_get, 0, 0}}} = Validate.validate(m)
  end

  test "a memory op with no memory section is rejected" do
    # i32.const 0 ; i32.load — but no memory declared
    m = mod(<<0, 0x41, 0, 0x28, 0, 0, 0x0B>>)
    assert {:error, {:invalid, {:memory_op_without_memory, :i32_load}}} = Validate.validate(m)
  end

  test "index checks recurse into block/loop/if bodies" do
    # block { call 99 } — bad index nested inside a block
    m = mod(<<0, 0x02, 0x40, 0x10, 99, 0x0B, 0x0B>>)
    assert {:error, {:invalid, {:call_index, 99, _}}} = Validate.validate(m)
  end

  test "the sandbox validates by default and refuses a malformed module" do
    m = mod(<<0, 0x10, 99, 0x0B>>)
    assert {:error, {:invalid, {:call_index, 99, _}}} = Sandbox.run(m, "f", [])
  end

  test "validation can be turned off at the sandbox (trusted caller)" do
    # with validate: false the bad call reaches the interpreter, which traps/errs in-process (contained)
    m = mod(<<0, 0x10, 99, 0x0B>>)
    refute match?({:error, {:invalid, _}}, Sandbox.run(m, "f", [], validate: false))
  end

  # ()->i32 module exporting "f" with the given body (locals byte included)
  defp mod(body) do
    bsz = byte_size(body)
    code = <<10, bsz + 2, 1, bsz>> <> body
    {:ok, m} =
      Washy.decode(
        <<0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 0x60, 0, 1, 0x7F, 3, 2, 1, 0, 7, 5, 1, 1, 0x66, 0, 0>> <>
          code
      )

    m
  end
end
