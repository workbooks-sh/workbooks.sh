defmodule Workbooks.Secret.Env do
  @moduledoc """
  Local/dev secret backend: values from a configured map
  (`config :workbooks, :secrets, %{"NAME" => "value"}`) and then the OS
  environment. The prod cells swap this for 1Password/AWS/Vault/Varlock — same
  `Workbooks.Secret` behaviour, no core change (docs/SECRETS.org).
  """
  @behaviour Workbooks.Secret

  @impl true
  def get(name) do
    case Map.get(configured(), name) || System.get_env(name) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @impl true
  def present?(name), do: Map.has_key?(configured(), name) or System.get_env(name) != nil

  defp configured, do: Application.get_env(:workbooks, :secrets, %{})
end
