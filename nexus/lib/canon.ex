defmodule Nexus.Canon do
  @moduledoc """
  Injective canonical encoding for signing preimages (epic wb-kodp, fix wb-talp).

  Signed messages are built from `key=value` fields joined by `\\n`. If a field could itself contain a
  `\\n` or `=`, two DIFFERENT field sets would serialize to the SAME bytes — so one signature could be
  lifted onto a forged set that gains an unauthorized field. The single defense is to make the encoding
  INJECTIVE: percent-escape the three structural characters (`%`, `\\n`, `=`) inside every key and value
  before joining, so the delimiters can only ever appear as delimiters. One home, shared by every signed
  preimage (`Nexus.Attest`, `Nexus.Authorship`), so the rule can't drift between message types.
  """

  @doc "Escape the structural chars so a field can't forge a delimiter. Reversible via `unescape/1`."
  @spec escape(term()) :: String.t()
  def escape(s) do
    s
    |> to_string()
    |> String.replace("%", "%25")
    |> String.replace("\n", "%0A")
    |> String.replace("=", "%3D")
  end

  @doc "Inverse of `escape/1` (unescape the `\\n`/`=` codes first, the literal `%` last)."
  @spec unescape(String.t()) :: String.t()
  def unescape(s) do
    s
    |> String.replace("%0A", "\n")
    |> String.replace("%3D", "=")
    |> String.replace("%25", "%")
  end

  @doc "Canonical, injective `key=value` block: keys sorted, each key+value escaped, lines joined by `\\n`."
  @spec kv(map()) :: String.t()
  def kv(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {escape(k), escape(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("\n")
  end

  @doc "Parse a `kv/1` block back to a `%{escaped-unescaped string => string}` map (round-trips `kv/1`)."
  @spec parse_kv(String.t()) :: map()
  def parse_kv(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> {unescape(k), unescape(v)}
        [k] -> {unescape(k), ""}
      end
    end)
  end
end
