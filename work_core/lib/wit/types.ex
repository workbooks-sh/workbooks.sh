defmodule WorkCore.Wit.Types do
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

  @doc """
  Render a WIT `record` from a name and its `[{field, default}]` pairs. Given the
  in-scope enums (`[{enum_name, atoms}]`), a field whose default atom is a member of
  an enum types as that enum (e.g. `status: :new` with `statuses` → `status: statuses`).
  """
  def record(name, fields, enums \\ []) do
    body =
      fields
      |> Enum.map(fn {field, default} -> "  #{wit(field)}: #{field_type(default, enums)}," end)
      |> Enum.join("\n")

    "record #{wit(name)} {\n#{body}\n}"
  end

  defp field_type(default, enums) when is_atom(default) and not is_boolean(default) and not is_nil(default) do
    case Enum.find(enums, fn {_name, atoms} -> default in atoms end) do
      {enum_name, _atoms} -> wit(enum_name)
      nil -> scalar(default)
    end
  end

  defp field_type(default, _enums), do: scalar(default)

  @doc "Render a WIT `enum` from a name and its atom cases."
  def enum(name, atoms) do
    cases = atoms |> Enum.map(&("  " <> wit(&1) <> ",")) |> Enum.join("\n")
    "enum #{wit(name)} {\n#{cases}\n}"
  end

  @doc "Render a WIT `variant` from a name and its tag cases (payloads default to string)."
  def variant(name, tags) do
    cases = tags |> Enum.map(&("  " <> wit(&1) <> "(string),")) |> Enum.join("\n")
    "variant #{wit(name)} {\n#{cases}\n}"
  end

  # WIT reserved words — must be %-escaped to be used as identifiers
  @wit_keywords ~w(use type resource func record enum flags variant union bool
    s8 s16 s32 s64 u8 u16 u32 u64 f32 f64 char string list option result tuple
    future stream world import export package interface include with as from
    static constructor borrow own and or)

  @doc """
  WIT identifier form: lowercased, snake_case → kebab-case, with Elixir predicate/
  bang suffixes (`?`/`!`) and any other illegal characters dropped, and reserved
  words %-escaped (`from` → `%from`).
  """
  def wit(name) do
    base =
      name
      |> to_string()
      |> String.replace("_", "-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "")

    if base in @wit_keywords, do: "%" <> base, else: base
  end
end
