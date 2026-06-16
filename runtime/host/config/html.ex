defmodule Workbooks.Config.HTML do
  @moduledoc """
  Read a single declarative config element out of an HTML config file into the
  uppercase property map the deploy/publish kits validate against.

  A config file is a workbook fragment with ONE `<work-deploy …>` /
  `<work-publish …>` element; its attributes ARE the config. Floki parses it (the
  same HTML-native reader `Workbooks.Workbook` uses) — no bespoke format, no org
  parser. Attribute names are lower-kebab in HTML; we normalize them to the legacy
  UPPER_SNAKE keys (`engine-place` → `ENGINE_PLACE`) so the validate/to_env logic
  is shared and unchanged.

  The file is inert config — never executed. SECRETS never go in attributes; they
  come from the deploy ENV.
  """

  @doc """
  Parse `body` (HTML) → `%{"UPPER_SNAKE" => "value"}` from the first `tag`
  element's attributes. An absent element (or unparseable HTML) yields `%{}`.
  """
  @spec props(binary(), binary()) :: %{optional(String.t()) => String.t()}
  def props(body, tag) when is_binary(body) and is_binary(tag) do
    with {:ok, tree} <- Floki.parse_fragment(body),
         [node | _] <- Floki.find(tree, tag) do
      node
      |> attrs()
      |> Map.new(fn {k, v} -> {key(k), String.trim(to_string(v))} end)
    else
      _ -> %{}
    end
  end

  defp attrs({_tag, attrs, _children}), do: attrs
  defp attrs(_), do: []

  # engine-place → ENGINE_PLACE
  defp key(k), do: k |> String.upcase() |> String.replace("-", "_")
end
