defmodule Wasmex.Components.Instance do
  @moduledoc """
  The component model equivalent to `Wasmex.Instance`
  """
  defstruct store_resource: nil,
            instance_resource: nil,
            # The actual NIF store resource.
            # Normally the compiler will happily do stuff like inlining the
            # resource in attributes. This will convert the resource into an
            # empty binary with no warning. This will make that harder to
            # accidentally do.
            reference: nil

  def __wrap_resource__(store_resource, instance_resource) do
    %__MODULE__{
      store_resource: store_resource,
      instance_resource: instance_resource,
      reference: make_ref()
    }
  end

  def new(store_or_caller, component, imports) do
    %{resource: store_or_caller_resource} = store_or_caller
    %{resource: component_resource} = component

    case Wasmex.Native.component_instance_new(
           store_or_caller_resource,
           component_resource,
           imports
         ) do
      {:error, err} -> {:error, err}
      resource -> {:ok, __wrap_resource__(store_or_caller_resource, resource)}
    end
  end

  def call_function(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        function_or_path,
        args,
        from
      ) do
    function_path = parse_function_path(function_or_path)

    Wasmex.Native.component_call_function(
      store_resource,
      instance_resource,
      function_path,
      args,
      from
    )
  end

  @doc """
  Drive a guest that exports `wasi:http/incoming-handler` with a synthesized request — the inbound
  standard-component seam (wb-py4k). Returns `{status, headers, body}` (body as a binary).
  """
  def serve_http(
        %__MODULE__{store_resource: store_resource, instance_resource: instance_resource},
        method,
        uri,
        headers,
        body
      ) do
    # body crosses the NIF as a byte list (rustler decodes Vec<u8> from a list, not a binary)
    case Wasmex.Native.component_serve_http(
           store_resource,
           instance_resource,
           method,
           uri,
           headers,
           :binary.bin_to_list(body)
         ) do
      {status, hdrs, body_bytes} when is_integer(status) and is_list(body_bytes) ->
        {status, hdrs, :erlang.list_to_binary(body_bytes)}

      other ->
        other
    end
  end

  defp parse_function_path(path) when is_binary(path), do: [path]
  defp parse_function_path(path) when is_atom(path), do: [Atom.to_string(path)]

  defp parse_function_path(path) when is_list(path) do
    Enum.map(path, fn
      p when is_binary(p) -> p
      p when is_atom(p) -> Atom.to_string(p)
    end)
  end

  defp parse_function_path(path) when is_tuple(path) do
    path
    |> Tuple.to_list()
    |> parse_function_path()
  end
end
