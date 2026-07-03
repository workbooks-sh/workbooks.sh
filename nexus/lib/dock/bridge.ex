defmodule Nexus.Dock.Bridge do
  @moduledoc """
  The `__host_call` ABI handler for the TL core-wasm lane (route (a) of wb-vhq1u) — the BEAM-native
  replacement for the wasm component-model import table (`Nexus.Sandbox` / wasmex).

  A retargeted guest unit (rust/c/zig/swift compiled to CORE wasm, NOT componentized) imports ONE host
  function — the same proven ABI `Nexus.Compilers.Js.PorfforHost` already runs on TinyLasers.Wasm:

      __host_call(opPtr, opLen, reqPtr, reqLen, resPtr, resCap) -> resLen   (-1 on overflow/unknown)

  `op` names a Dock host fn; `req`/`res` are JSON bytes (the "typed marshaling" the component model used
  to do is derivable from the `Dock.host_fn_wit` sig — args are a JSON array, the result is JSON). The
  bridge routes `op` through `Nexus.Dock.impls/2`, which is ALREADY tenant-bound + grant-filtered — so
  the exact capability confinement wasmex gave (a guest reaches only granted, tenant-partitioned caps)
  is preserved, now enforced in BEAM code we own, not a native NIF.

  The run harness installs `:dock_tenant` + `:dock_caps` in the process dict before invoking the guest
  (mirrors how `:tl_mem` / `:tl_imports` are planted); `dispatch/4` is pure (no guest memory) so the
  routing + marshaling + grant-filtering are unit-testable without a wasm run.
  """
  alias TinyLasers.Wasm, as: Washy

  @doc """
  The `__host_call` import, wired into a TL run's host-import table. Reads `op`/`req` from guest linear
  memory, dispatches, writes the JSON result back into the caller-allocated `res` region. Returns the
  byte count written (as a float — the wasm valtype) or `-1.0` on overflow / an ungranted-or-unknown op.
  """
  def host_call([op_ptr, op_len, req_ptr, req_len, res_ptr, res_cap]) do
    mem = Process.get(:tl_mem)
    op = Washy.read_bytes(mem, t(op_ptr), t(op_len))
    req = Washy.read_bytes(mem, t(req_ptr), t(req_len))
    tenant = Process.get(:dock_tenant) || Nexus.Store.default_tenant()
    caps = Process.get(:dock_caps) || :all

    case dispatch(op, req, tenant, caps) do
      {:ok, result} when is_binary(result) ->
        if byte_size(result) > t(res_cap) do
          -1.0
        else
          Washy.write_bytes(Process.get(:tl_mem), t(res_ptr), result)
          byte_size(result) * 1.0
        end

      :error ->
        -1.0
    end
  end

  @doc """
  Route one host call: `op` → `Dock.impls(tenant, caps)`, decode `req_json` as the typed args array,
  apply, JSON-encode the result. `{:ok, json} | :error`. An ungranted/unknown op → `:error` (the guest
  can't reach a capability it never granted — the confinement invariant, now in the bridge).
  """
  def dispatch(op, req_json, tenant, caps) do
    case Map.get(Nexus.Dock.impls(tenant, caps), op) do
      {:fn, impl} ->
        case decode_args(req_json) do
          {:ok, args} -> {:ok, Jason.encode!(apply(impl, args))}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  # req is a JSON array of the op's positional args (empty payload → zero-arg op like `now`).
  defp decode_args(""), do: {:ok, []}

  defp decode_args(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, scalar} -> {:ok, [scalar]}
      {:error, _} -> :error
    end
  end

  # wasm passes pointers/lengths as f64 (the guest valtype); truncate to integer addresses.
  defp t(v) when is_float(v), do: trunc(v)
  defp t(v), do: v
end
