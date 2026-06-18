defmodule Workbooks.Wit.Types do
  @moduledoc """
  §2.2 — map Elixir structure to WIT types. A `defstruct` becomes a WIT `record`,
  each field's type inferred from its **default value** (the format's rule: the
  default is the type). Scalars cover the data-model floor; `enum`/`variant` follow
  as the AST surfaces atom-sets and tagged tuples.
  """

  @doc "Infer the WIT scalar type for a struct field's default value."
  def scalar(v) when is_boolean(v), do: "bool"
  def scalar(v) when is_binary(v), do: "string"
  def scalar(v) when is_integer(v), do: "s32"
  def scalar(v) when is_float(v), do: "f64"
  def scalar(nil), do: "string"
  def scalar([]), do: "list<string>"
  def scalar(v) when is_atom(v), do: "string"
  def scalar(_), do: "string"

  @doc "Render a WIT `record` from a name and its `[{field, default}]` pairs."
  def record(name, fields) do
    body =
      fields
      |> Enum.map(fn {field, default} -> "  #{wit(field)}: #{scalar(default)}," end)
      |> Enum.join("\n")

    "record #{wit(name)} {\n#{body}\n}"
  end

  @doc "Render a WIT `enum` from a name and its atom cases."
  def enum(name, atoms) do
    cases = atoms |> Enum.map(&("  " <> wit(&1) <> ",")) |> Enum.join("\n")
    "enum #{wit(name)} {\n#{cases}\n}"
  end

  @doc "WIT identifier form: lowercased, snake_case → kebab-case."
  def wit(name), do: name |> to_string() |> String.replace("_", "-") |> String.downcase()
end
