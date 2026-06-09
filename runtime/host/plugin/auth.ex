defmodule Workbooks.Plugin.Auth do
  @moduledoc """
  Centralized credential fetch for federation plugins (wb-39j.2). A plugin's secret
  (named by `#+ENV_KEYS`) is resolved through THIS one point — never `System.get_env`
  scattered in plugin code — so credentials have a single audited resolution path.

  Resolution order: an optionally-configured resolver (the deploy's broker/keychain
  extension point) → process/host env. The broker tier is where a deploy plugs in a
  secrets manager; env is the working default.
  """

  @doc """
  Fetch the credential named `key`, or nil. `opts[:resolver]` (a `(key -> binary | nil)`
  fun) is tried first — the seam for a keychain/broker; otherwise the host env.
  """
  def fetch(key, opts \\ []) when is_binary(key) do
    via_resolver(key, opts[:resolver]) || System.get_env(key)
  end

  defp via_resolver(_key, nil), do: nil

  defp via_resolver(key, resolver) when is_function(resolver, 1) do
    case resolver.(key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
