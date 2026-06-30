defmodule TinyLasers.Js.HostObjects do
  @moduledoc """
  **Host-resident JS objects (externref ABI, handle realization).**

  Stage 2 of the objects-as-host-terms conversion (docs/research/externref-abi-inventory.md). A JS object
  is represented in the pair ABI as `[i32 handle, TYPES.object]` — the value slot holds an opaque i32
  handle into a *host-side* table that maps `handle → %{prop_hash => {value, type}}`. Property access
  becomes a host import call (a process-dict map read) instead of Porffor's linear-memory pointer-chase +
  20-branch type-tag dispatch. Measured at 1.03× of true externref and ~4× faster than the in-memory
  dispatch path, while keeping the pair ABI 100% intact (no externref valtype, no signature changes).

  Keys are Porffor's own property hash (`__Porffor_object_hash`, xxh32), computed in-guest, so these import
  closures never need to read guest linear memory. Values are stored as the pair `{value::float, type::int}`.

  ## Import surface (single-value returns — the runtime's host bridge pushes exactly one result)
    ho.new()                              -> i32 handle
    ho.set(handle, hash, value, type)     -> (void)
    ho.get_value(handle, hash)            -> f64   (0.0 if absent)
    ho.get_type(handle, hash)             -> i32   (TYPES.undefined = 0 if absent)
    ho.has(handle, hash)                  -> i32   (1/0)

  Install with `Process.put(:tl_imports, Map.merge(existing, TinyLasers.Js.HostObjects.imports()))`
  before a run; the per-run table lives in the process dictionary (one run = one process).
  """

  @tbl :tl_ho_tbl
  @next :tl_ho_next

  # TYPES.* tags used here (mirror compiler/types.js).
  @t_undefined 0

  # Host handles carry a high tag bit so a TYPES.object VALUE distinguishes a host handle from a real
  # linear-memory pointer at runtime (memory pointers are byte offsets < 1 GB = 0x40000000; bit 31 is
  # never a valid pointer). This lets the member typeSwitch branch host-vs-memory on the value itself —
  # covering dynamically-typed receivers (loop vars, params) that lose the static object type. The
  # codegen tests the same bit (Prefs constant HOST_OBJ_TAG); ho_* mask it off to index the table.
  @tag 0x80000000
  @mask 0x7FFFFFFF
  @doc "The handle tag bit (must match the codegen's HOST_OBJ_TAG)."
  def tag, do: @tag

  @doc "The `ho.*` host-import closures to merge into `:tl_imports`."
  def imports do
    # Keyed by the flat wasm field name Porffor emits (module "", field "ho_new", …). The runtime resolves
    # host imports as `Map.get(tbl, {m, name}) || Map.get(tbl, name)`, so the string key matches.
    %{
      "ho_new" => fn [] -> ho_new() end,
      "ho_set" => fn [h, hash, value, type] -> ho_set(h, hash, value, type) end,
      "ho_get_value" => fn [h, hash] -> ho_get_value(h, hash) end,
      "ho_get_type" => fn [h, hash] -> ho_get_type(h, hash) end,
      "ho_has" => fn [h, hash] -> ho_has(h, hash) end,
      "ho_delete" => fn [h, hash] -> ho_delete(h, hash) end
    }
  end

  @doc "Reset the per-run object table (call at run start if reusing a process)."
  def reset do
    Process.delete(@tbl)
    Process.delete(@next)
    :ok
  end

  # ── handle allocation ───────────────────────────────────────────────────────────────────────────
  defp ho_new do
    tbl = Process.get(@tbl, %{})
    h = Process.get(@next, 1)
    Process.put(@tbl, Map.put(tbl, h, %{}))
    Process.put(@next, h + 1)
    # return the TAGGED handle (high bit set) so the value is self-identifying as a host object.
    Bitwise.bor(h, @tag)
  end

  # strip the tag bit to get the table key (no-op if already untagged, e.g. hand-built test modules).
  defp untag(h), do: Bitwise.band(trunc(h), @mask)

  # ── set: store {value, type} at the property hash ───────────────────────────────────────────────
  defp ho_set(h, hash, value, type) do
    h = untag(h)
    hash = trunc(hash)
    tbl = Process.get(@tbl, %{})
    obj = Map.get(tbl, h, %{})
    Process.put(@tbl, Map.put(tbl, h, Map.put(obj, hash, {value / 1, trunc(type)})))
    nil
  end

  # ── get: split value/type so each import returns a single stack value ───────────────────────────
  defp ho_get_value(h, hash) do
    case lookup(h, hash) do
      {value, _type} -> value
      nil -> 0.0
    end
  end

  defp ho_get_type(h, hash) do
    case lookup(h, hash) do
      {_value, type} -> type
      nil -> @t_undefined
    end
  end

  defp ho_has(h, hash) do
    if lookup(h, hash), do: 1, else: 0
  end

  # delete: drop the property; return 1 if it existed, else 0 (JS `delete` is always 1 for own configurable
  # props, but the in-memory oracle returns truthy — we match its observable boolean).
  defp ho_delete(h, hash) do
    h = untag(h)
    hash = trunc(hash)
    tbl = Process.get(@tbl, %{})
    obj = Map.get(tbl, h, %{})
    Process.put(@tbl, Map.put(tbl, h, Map.delete(obj, hash)))
    1
  end

  defp lookup(h, hash) do
    Process.get(@tbl, %{})
    |> Map.get(untag(h), %{})
    |> Map.get(trunc(hash))
  end
end
