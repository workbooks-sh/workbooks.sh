defmodule Nexus.HashNote.Guard do
  @moduledoc """
  **Guardrail graduation** — where a drawered `-#` note stops being a footnote and starts
  defending the codebase. A note marked `#guard` carrying a `/pattern/` becomes a tripwire:

      -# #guard never read secrets directly — use Nexus.Secrets /System\\.get_env/

  Once swept, that guardrail lives in the drawer. `scan/2` greps arbitrary content (a diff,
  a file, a proposed edit) against every guardrail's pattern and surfaces the ORIGINATING
  note on a match — so the lesson a prior agent recorded ("don't do X, it broke Y") actively
  blocks the next agent from repeating it, instead of waiting to be read.
  """

  alias Nexus.HashNote

  @guard_tag "#guard"

  @doc "All drawered notes that are guardrails (text carries `#guard` and a `/pattern/`)."
  def guards(tenant \\ nil) do
    mod = HashNote.resource_mod()
    rows = if tenant, do: Nexus.Store.all(mod, tenant), else: Nexus.Store.all(mod)

    rows
    |> Enum.filter(&guard?/1)
    |> Enum.flat_map(fn row ->
      case parse(row.text) do
        {:ok, pattern, message} -> [%{hash: row.hash, file: row.file, pattern: pattern, message: message}]
        :error -> []
      end
    end)
  end

  @doc """
  Scan `content` against every guardrail. Returns a list of violations
  `%{hash, file, pattern, message, match}` — empty when clean. The caller feeds whatever it
  wants checked (a unified diff, a file's text, a candidate edit).
  """
  def scan(content, tenant \\ nil) when is_binary(content) do
    guards(tenant)
    |> Enum.flat_map(fn g ->
      case compile(g.pattern) do
        {:ok, re} ->
          case Regex.run(re, content) do
            [m | _] -> [Map.put(g, :match, m)]
            _ -> []
          end

        :error ->
          []
      end
    end)
  end

  @doc "True when a guardrail's pattern fires anywhere in `content`."
  def tripped?(content, tenant \\ nil), do: scan(content, tenant) != []

  # ── parsing a guard note ────────────────────────────────────────────────────
  # `#guard <message> /<regex>/` — the LAST `/…/` is the pattern; the message is the rest,
  # with the `#guard` tag and the pattern removed.
  defp parse(text) do
    case Regex.run(~r{/([^/]+)/}, text) do
      [whole, pattern] ->
        message =
          text
          |> String.replace(whole, "")
          |> String.replace(@guard_tag, "")
          |> String.trim()

        {:ok, pattern, message}

      _ ->
        :error
    end
  end

  defp guard?(row) do
    is_binary(row.text) and String.contains?(row.text, @guard_tag) and
      Regex.match?(~r{/[^/]+/}, row.text)
  end

  defp compile(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, re}
      _ -> :error
    end
  end
end
