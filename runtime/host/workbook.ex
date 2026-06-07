defmodule Workbooks.Workbook do
  @moduledoc """
  Parse a Workbook artifact and extract its Spec. A Workbook is one HTML file
  with an inline `<script id="workbook-spec">` (the self-description) and the
  Org source it tangles from. Format is identified by the inline marker, not
  the filename.
  """

  @doc "Extract the Workbook Spec (JSON) from artifact HTML."
  def spec(html) when is_binary(html) do
    case Regex.run(~r/<script id="workbook-spec"[^>]*>(.*?)<\/script>/s, html) do
      [_, json] -> Jason.decode(json)
      _ -> {:error, :no_spec}
    end
  end

  @doc "Extract the embedded Org source block (the literate source) from artifact HTML."
  def org_source(html) when is_binary(html) do
    case Regex.run(~r/<script id="workbook-org"[^>]*>(.*?)<\/script>/s, html) do
      [_, org] -> {:ok, org}
      _ -> {:error, :no_org}
    end
  end
end
