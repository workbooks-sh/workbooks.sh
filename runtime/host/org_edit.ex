defmodule Workbooks.OrgEdit do
  @moduledoc """
  Minimal, surgical Org headline edits for the kanban board (wb-kbq5,
  PATCH /api/oql/headline/:id). OQL parses + renders but doesn't mutate, so the
  board's card moves (transition_todo) and field edits (set_property) are done
  here as line-level text edits that preserve everything else in the file.

  A headline is located by its `:ID:` property. Edits are intentionally narrow —
  this is not a general Org writer.
  """

  # The TODO keywords we recognize when rewriting a headline's state. Anything
  # the board sends is accepted as the NEW state; this set only disambiguates an
  # EXISTING leading keyword from the first word of a title.
  @keywords ~w(TODO DONE DOING NEXT WAIT WAITING CANCELLED CANCELED HOLD BLOCKED REVIEW)

  @doc "Apply an op to the headline with `id` in `org`. Returns {:ok, new_org} | {:error, reason}."
  def patch(org, id, op, args) when is_binary(org) do
    lines = String.split(org, "\n")

    case headline_index(lines, id) do
      nil -> {:error, :not_found}
      idx -> apply_op(lines, idx, op, args)
    end
  end

  # ── locate ─────────────────────────────────────────────────────────────────
  # Find the headline line index whose properties drawer carries :ID: <id>.
  defp headline_index(lines, id) do
    id_re = ~r/^\s*:ID:\s+#{Regex.escape(id)}\s*$/

    case Enum.find_index(lines, &Regex.match?(id_re, &1)) do
      nil -> nil
      id_idx -> nearest_headline_above(lines, id_idx)
    end
  end

  defp nearest_headline_above(lines, from) do
    Enum.reduce_while(from..0//-1, nil, fn i, _ ->
      if Regex.match?(~r/^\*+\s/, Enum.at(lines, i)), do: {:halt, i}, else: {:cont, nil}
    end)
  end

  # ── ops ──────────────────────────────────────────────────────────────────--
  defp apply_op(lines, hl_idx, "transition_todo", %{"state" => state}) when is_binary(state) do
    {:ok, lines |> List.update_at(hl_idx, &set_state(&1, state)) |> Enum.join("\n")}
  end

  defp apply_op(lines, hl_idx, "set_property", %{"name" => name, "value" => value})
       when is_binary(name) and is_binary(value) do
    {:ok, lines |> set_property(hl_idx, name, value) |> Enum.join("\n")}
  end

  defp apply_op(lines, hl_idx, "append_logbook", %{"entry" => entry}) when is_binary(entry) do
    # Insert a logbook line right after the headline (or its drawer). Cheap, good
    # enough for the board's note appends.
    insert_at = drawer_end(lines, hl_idx) + 1
    {:ok, lines |> List.insert_at(insert_at, "  - #{entry}") |> Enum.join("\n")}
  end

  defp apply_op(_lines, _idx, op, _args), do: {:error, {:unsupported_op, op}}

  # Rewrite a headline's leading TODO keyword (or insert one if absent).
  defp set_state(line, state) do
    case Regex.run(~r/^(\*+)\s+(\S+)(\s+.*)?$/, line) do
      [_, stars, first, rest] ->
        rest = rest || ""

        if first in @keywords do
          # replace existing keyword
          String.trim_trailing("#{stars} #{state}#{rest}")
        else
          # no keyword — `first` is part of the title; prepend the state
          String.trim_trailing("#{stars} #{state} #{first}#{rest}")
        end

      _ ->
        # bare "*" headline with no title
        String.trim_trailing("#{line} #{state}")
    end
  end

  # Set or replace a property in the headline's :PROPERTIES: drawer, creating the
  # drawer immediately under the headline if none exists.
  defp set_property(lines, hl_idx, name, value) do
    prop_line = ":#{name}: #{value}"

    case drawer_bounds(lines, hl_idx) do
      {start_i, end_i} ->
        key_re = ~r/^\s*:#{Regex.escape(name)}:\s/

        existing = Enum.find_index(Enum.slice(lines, start_i..end_i), &Regex.match?(key_re, &1))

        if existing do
          List.replace_at(lines, start_i + existing, "  #{prop_line}")
        else
          List.insert_at(lines, end_i, "  #{prop_line}")
        end

      nil ->
        # No drawer — insert one right after the headline.
        List.insert_at(lines, hl_idx + 1, "  :PROPERTIES:\n  #{prop_line}\n  :END:")
    end
  end

  # The {start, end} line indices of the :PROPERTIES:/:END: drawer immediately
  # following a headline, or nil. `end` is the :END: line.
  defp drawer_bounds(lines, hl_idx) do
    next = Enum.at(lines, hl_idx + 1, "")

    if Regex.match?(~r/^\s*:PROPERTIES:\s*$/, next) do
      end_i =
        Enum.reduce_while((hl_idx + 2)..(length(lines) - 1)//1, nil, fn i, _ ->
          if Regex.match?(~r/^\s*:END:\s*$/, Enum.at(lines, i)), do: {:halt, i}, else: {:cont, nil}
        end)

      if end_i, do: {hl_idx + 1, end_i}, else: nil
    end
  end

  defp drawer_end(lines, hl_idx) do
    case drawer_bounds(lines, hl_idx) do
      {_s, e} -> e
      nil -> hl_idx
    end
  end
end
