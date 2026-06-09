defmodule Workbooks.KernelRegistry do
  @moduledoc """
  name → content-addressed `bytes → bytes` KERNEL `.wasm` (wb-pkh.11). The kernel
  counterpart of CommandRegistry: a `command` is stdio + invoked via `run-command`;
  a `kernel` is a reactor opened ONCE by Workbooks.Kernel and looped per frame by
  Fabric.map_kernel. Different invocation contract → its own tiny registry, so a
  kernel is never accidentally stdio-run as a command.

  Dynamic, in :persistent_term (rare write, fast read), like the command registry.
  """

  @dynamic {__MODULE__, :kernels}
  @name_re ~r/^[A-Za-z0-9_.-]+$/
  @max 4096

  @doc "Register a built kernel: content-address it (build/commands/<sha>.wasm) and map `name` → path."
  def register(name, wasm_path) do
    cond do
      not is_binary(name) or name == "" or not Regex.match?(@name_re, name) ->
        {:error, :invalid_name}

      true ->
        case Workbooks.PackageManager.content_address(wasm_path) do
          {:ok, addressed, _sha} ->
            cur = :persistent_term.get(@dynamic, %{})

            if not Map.has_key?(cur, name) and map_size(cur) >= @max do
              {:error, :registry_full}
            else
              :persistent_term.put(@dynamic, Map.put(cur, name, addressed))
              {:ok, addressed}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "The content-addressed `.wasm` path for a registered kernel, or nil."
  def path(name), do: Map.get(:persistent_term.get(@dynamic, %{}), name)

  @doc "Registered kernel names."
  def list, do: Map.keys(:persistent_term.get(@dynamic, %{}))
end
