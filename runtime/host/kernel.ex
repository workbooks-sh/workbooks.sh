defmodule Workbooks.Kernel do
  @moduledoc """
  The hot kernel invocation path (wb-rhs.5): instantiate a `bytes → bytes` wasm
  kernel ONCE and call it many times, reusing the instance and a fixed in/out
  ARENA — no per-call instantiation, no stdio marshalling. This is the
  `#+EXEC: kernel` shape: the fabric (Workbooks.Fabric) loops a kernel per frame,
  and the per-call cost is one function call + two memory copies, not a fresh
  wasmtime Store + a WASI stdio round-trip each time (what `command` shape pays).

  ## The kernel ABI

  A kernel module exports a `memory` and an entry function (default `process`):

      process(in_len: i32) -> out_len: i32

  The host writes the input bytes at `:in_off` (default 1024), calls the entry
  with the input length, and reads `out_len` bytes back from `:out_off` (default
  65536). The arena offsets are FIXED and REUSED across calls — zero per-frame
  allocation. (True zero-copy across the NIF boundary would need shared linear
  memory; Wasmex copies, so this is "one reusable arena + one copy each way", the
  best available today. The `frames` Dock cap — a host-owned shared arena — is the
  next step to drop even that copy; tracked here.)

  ## Lifecycle

      {:ok, k} = Kernel.open(File.read!("decode_frame.wasm"))
      {:ok, out} = Kernel.call(k, frame_bytes)   # call per frame, instance reused
      Kernel.close(k)
  """
  use GenServer

  @in_off 1024
  @out_off 65_536
  @default_timeout 60_000

  @doc """
  Open a kernel: instantiate the wasm ONCE into a persistent instance. opts:
    * `:entry`   — exported entry fn (default "process")
    * `:in_off`  — input arena offset (default #{@in_off})
    * `:out_off` — output arena offset (default #{@out_off})
    * `:timeout` — per-call wall-clock ms (default #{@default_timeout})
  Returns `{:ok, kernel}` (a pid).
  """
  def open(wasm_bytes, opts \\ []) when is_binary(wasm_bytes) do
    GenServer.start_link(__MODULE__, {wasm_bytes, opts})
  end

  @doc "Call the kernel on `input` bytes → `{:ok, output_bytes}` | `{:error, reason}`. Instance reused."
  def call(kernel, input) when is_pid(kernel) and is_binary(input) do
    GenServer.call(kernel, {:call, input}, :infinity)
  end

  @doc "Close the kernel (drop the instance)."
  def close(kernel) when is_pid(kernel), do: GenServer.stop(kernel)

  @impl true
  def init({bytes, opts}) do
    with {:ok, pid} <- Wasmex.start_link(%{bytes: bytes}),
         {:ok, store} <- Wasmex.store(pid),
         {:ok, mem} <- Wasmex.memory(pid),
         {:ok, in_off, out_off} <- arena_offsets(pid, opts) do
      {:ok,
       %{
         pid: pid,
         store: store,
         mem: mem,
         entry: opts[:entry] || "process",
         in_off: in_off,
         out_off: out_off,
         timeout: opts[:timeout] || @default_timeout
       }}
    else
      {:error, reason} -> {:stop, {:kernel_open_failed, reason}}
    end
  end

  # Where the in/out arena lives. `:fixed` (default) trusts configured offsets —
  # right for a hand-authored module that controls its whole memory. `:exports`
  # asks the kernel where its buffers are (in_ptr/out_ptr exports) — right for a
  # COMPILED kernel (C/Zig), where the linker, not the author, places the static
  # buffers, so the host can't assume a fixed address.
  defp arena_offsets(pid, opts) do
    case opts[:arena] || :fixed do
      :fixed ->
        {:ok, opts[:in_off] || @in_off, opts[:out_off] || @out_off}

      :exports ->
        with {:ok, [in_off]} <- Wasmex.call_function(pid, opts[:in_ptr_fn] || "in_ptr", []),
             {:ok, [out_off]} <- Wasmex.call_function(pid, opts[:out_ptr_fn] || "out_ptr", []) do
          {:ok, in_off, out_off}
        end
    end
  end

  @impl true
  def handle_call({:call, input}, _from, s) do
    # Write input into the reused arena, call the entry with its length, read the
    # returned length back out. No re-instantiation; the same Store/memory persist.
    with :ok <- Wasmex.Memory.write_binary(s.store, s.mem, s.in_off, input),
         {:ok, [out_len]} when is_integer(out_len) and out_len >= 0 <-
           Wasmex.call_function(s.pid, s.entry, [byte_size(input)], s.timeout) do
      out = Wasmex.Memory.read_binary(s.store, s.mem, s.out_off, out_len)
      {:reply, {:ok, out}, s}
    else
      {:ok, other} -> {:reply, {:error, {:bad_entry_result, other}}, s}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end
end
