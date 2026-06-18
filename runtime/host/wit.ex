defmodule Workbooks.Wit do
  @moduledoc """
  §2 — generate a per-unit **WIT world** from the parsed unit: `export`s from the
  AST signature (`Extract.facts` public defs), `import`s from the unit's `grant`s.
  This is the third code-graph feed and the contract you never hand-write — the
  thing the demo's `contract.work` shows once, labelled "generated".

  This is the world *skeleton*: param/return types default to `string` until the
  full `Workbooks.Wit.Types` mapping lands (§2.2 — record/variant/enum/flags from
  the unit's declared structs). A unit with no signature gets the default `run`.
  """

  alias Workbooks.Extract

  # grant capability → the host interface it imports across the Dock seam
  @grant_imports %{
    "net" => "host:net/fetch",
    "kv" => "host:kv/store",
    "fs" => "host:fs/files",
    "secrets" => "host:secrets/read",
    "exec" => "host:exec/run",
    "queue" => "host:queue/push",
    "llm" => "host:llm/complete",
    "browse" => "host:browse/fetch"
  }

  @caps Map.keys(@grant_imports) ++ ~w(tcp udp tls posix parallel encode commands)

  @doc "Generate the WIT `world` source for a `Workbooks.Literate` :code node."
  def world(%{name: name} = node) when is_binary(name) do
    exports = node |> Extract.facts() |> Map.fetch!(:exports) |> export_lines()
    exports = if exports == [], do: ["export run: func(input: string) -> string;"], else: exports
    imports = node |> grants() |> Enum.map(&grant_import/1) |> Enum.reject(&is_nil/1)

    body = (exports ++ imports) |> Enum.map(&("  " <> &1)) |> Enum.join("\n")

    "package work:#{wit_name(name)};\n\nworld #{wit_name(name)} {\n#{body}\n}\n"
  end

  def world(_), do: nil

  @doc "Parse the capability names a unit grants, from its block header."
  def grants(%{header: header}) when is_binary(header) do
    # words inside a `grant[:] [ … ]` bracket (handles `net:` and `:net` forms),
    # plus a bare `grant net`; filtered to known caps so string values don't leak.
    in_bracket =
      case Regex.run(~r/grant:?\s*\[([^\]]*)\]/, header, capture: :all_but_first) do
        [inner] ->
          # keyword form `[net: "x", kv: :y]` → the KEYS are caps (values aren't);
          # atom-list form `[:net, :kv]` → the items are caps.
          if Regex.match?(~r/[a-z]+:/, inner),
            do: Regex.scan(~r/([a-z]+):/, inner) |> Enum.map(&List.last/1),
            else: Regex.scan(~r/:([a-z]+)/, inner) |> Enum.map(&List.last/1)

        _ ->
          []
      end

    bare = Regex.scan(~r/\bgrant\s+([a-z]+)\b/, header) |> Enum.map(&List.last/1)

    (in_bracket ++ bare) |> Enum.filter(&(&1 in @caps)) |> Enum.uniq()
  end

  def grants(_), do: []

  # ── private ──

  defp export_lines(exports) do
    Enum.map(exports, fn
      {name, arity} when is_integer(arity) ->
        "export #{wit_name(name)}: func(#{params(arity)}) -> string;"

      name ->
        "export #{wit_name(name)}: func() -> string;"
    end)
  end

  defp params(0), do: ""
  defp params(arity), do: 0..(arity - 1) |> Enum.map(&"a#{&1}: string") |> Enum.join(", ")

  defp grant_import(cap), do: if(wit = @grant_imports[cap], do: "import #{wit};")

  defp wit_name(name), do: name |> to_string() |> String.replace("_", "-")
end
