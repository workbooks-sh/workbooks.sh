defmodule Nexus.Uid do
  @moduledoc """
  §1 — the canonical identity of a work unit. One authored name, many surface
  forms. Before this module the same logical unit wore a different mask in every
  layer: a downcased string key in the graph (§9), a kebab-cased `work:` package
  in the WIT feed (§2), a `Macro.camelize`d Elixir module in the compiler. Each
  layer re-derived its own form, so the layers could not agree on what "the same
  unit" was. `Uid` is the single home for those conversions; every layer projects
  through it. Pure form — no parsing, no IO, no behaviour beyond string shape.
  """

  # WIT reserved words: a unit name colliding with one is %-escaped so the
  # generated package still validates (§2.2's rule, moved here from Wit.Types).
  @wit_keywords ~w(use type resource func record enum flags variant union bool
    s8 s16 s32 s64 u8 u16 u32 u64 f32 f64 char string list option result tuple
    future stream world import export package interface include with as from
    static constructor borrow own and or)

  @doc """
  Graph key form: the identity two edges compare on. Authored unit names are
  lowercase; a call-derived name (`Module → "lead"`) is downcased to match. This
  is the key under which a unit lives in `Graph.nodes` and the target an edge
  resolves against.
  """
  def key(name), do: name |> to_string() |> String.downcase()

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

  @doc "WIT package id for a unit: `work:<wit>`."
  def package(name), do: "work:" <> wit(name)

  @doc """
  Camelized base form (`"lead"` → `"Lead"`) — the spelling the compiler turns into
  an Elixir module. Exposed so the one camelize step has a single home even where
  callers append a hot-reload suffix.
  """
  def camel(name), do: name |> to_string() |> Macro.camelize()

  @doc "Elixir module form for a unit: `Lead`."
  def module(name), do: Module.concat([camel(name)])

  @doc "Elixir module form nested under a base namespace: `module(\"lead\", Nexus.Units)` → `Nexus.Units.Lead`."
  def module(name, base), do: Module.concat([base, camel(name)])

  @doc """
  Guard a unit name against clobbering a runtime-critical module.

  A `resource`/`server` unit compiles (via `module/1`) to a **top-level** BEAM module of
  the camelized name. A unit named `Task`/`Map`/`Enum`/`Process` therefore *overwrites*
  Elixir's stdlib module of that name — e.g. `resource Task` redefined `Elixir.Task`,
  erasing `Task.start_link/3`, the function the web server's socket acceptors spawn through;
  the nexus then died on boot. (See the dogfood `Todo` rename + wb-o5ng.)

  Discriminator: at workbook-compile time a runtime module is already **loaded**, whereas a
  fresh author name (`Todo`, `Lead`) is not. We refuse any name whose module is loaded and is
  NOT itself a previously-compiled workbook unit (those carry `__nexus_unit__/0`, so a *recompile*
  of a real unit still passes). Returns `:ok` or `{:error, message}`.
  """
  def guard(name) do
    mod = module(name)

    cond do
      not match?({:module, _}, Code.ensure_loaded(mod)) -> :ok
      function_exported?(mod, :__nexus_unit__, 0) -> :ok
      true ->
        {:error,
         "unit name #{inspect(name)} would shadow the runtime module #{inspect(mod)} that the " <>
           "nexus depends on — pick a non-colliding name (e.g. `Task` → `Todo`, `Map` → `Mapping`)."}
    end
  end

  @doc """
  Normalize a free-text label (a `[[backlink]]`, a prose mention) to a graph key:
  strip wiki brackets, lowercase, and drop the `the …`/`… agent`/`… kit` affixes
  the literate refs (§0.1) carry so a mention resolves to a unit key.
  """
  def normalize(nil), do: ""

  def normalize(label) do
    label
    |> to_string()
    |> String.trim_leading("[[")
    |> String.trim_trailing("]]")
    |> String.downcase()
    |> String.replace_leading("the ", "")
    |> String.replace_trailing(" agent", "")
    |> String.replace_trailing(" kit", "")
    |> String.trim()
  end
end
