defmodule Nexus.Chat do
  @moduledoc """
  Chat semantics over the store — **threads, reactions, and unread** (open standard, generic
  mechanism). The durable shapes are ordinary `resource`s a product declares (so they ride the same
  tenant partitioning, live-shapes deltas, and pagination as everything else); this module is the
  pure logic that turns flat rows into the views a Slack-like UI needs. Kept deliberately data-shape
  agnostic: it works on any map/struct carrying the documented keys, so it's trivially testable and
  reusable across the cloud app and any workbook.

  ## The canonical shapes (declared as `.work` resources by the product)

      resource Message do
        channel    :text     # which channel/surface this belongs to
        author     :text     # user id
        body       :text
        parent     :text     # "" = top-level; else the id of the message this replies to (THREADS)
        ts         :integer  # unix ms, monotonic-ish order key
      end

      resource Reaction do
        message :text        # the message id reacted to
        emoji   :text
        author  :text
        ts      :integer
      end

      resource Cursor do
        channel :text        # read cursor: how far a user has read in a channel
        user    :text
        ts      :integer     # last-read message ts
      end

  `parent` is the whole threading model — one nullable-ish field, added to the model *now* (cheap)
  instead of retrofitted onto a flat store later (painful).
  """

  # A row is any map/struct with string-or-atom-ish keys; we read via a tolerant getter so callers can
  # pass structs (server) or plain maps (decoded JSON) without converting first.
  defp get(row, key) do
    cond do
      is_map(row) and Map.has_key?(row, key) -> Map.get(row, key)
      is_map(row) and Map.has_key?(row, to_string(key)) -> Map.get(row, to_string(key))
      true -> nil
    end
  end

  defp id(row), do: get(row, :id)
  defp parent(row), do: get(row, :parent) || ""
  defp ts(row), do: get(row, :ts) || 0

  # ── threads ──────────────────────────────────────────────────────────────────────────────────────

  @doc "Top-level messages (no parent), oldest-first by `ts`."
  @spec roots([map]) :: [map]
  def roots(messages) do
    messages |> Enum.filter(&(parent(&1) in [nil, ""])) |> Enum.sort_by(&ts/1)
  end

  @doc "Direct replies to `parent_id`, oldest-first."
  @spec replies([map], term) :: [map]
  def replies(messages, parent_id) do
    messages |> Enum.filter(&(parent(&1) == parent_id)) |> Enum.sort_by(&ts/1)
  end

  @doc """
  Assemble a threaded view: `[%{message:, replies:, reply_count:, last_reply_ts:}]`, one entry per
  root, oldest-first, with that root's direct replies attached (oldest-first). Replies-of-replies are
  flattened under their nearest root (Slack-style single-level threads).
  """
  @spec threads([map]) :: [map]
  def threads(messages) do
    # Map every message to the root it ultimately hangs from, so a reply-to-a-reply still files under
    # the visible thread root.
    by_id = Map.new(messages, &{id(&1), &1})
    root_of = fn msg -> climb_to_root(msg, by_id) end

    grouped =
      messages
      |> Enum.reject(&(parent(&1) in [nil, ""]))
      |> Enum.group_by(fn msg -> id(root_of.(msg)) end)

    for root <- roots(messages) do
      rs = grouped |> Map.get(id(root), []) |> Enum.sort_by(&ts/1)

      %{
        message: root,
        replies: rs,
        reply_count: length(rs),
        last_reply_ts: rs |> Enum.map(&ts/1) |> Enum.max(fn -> ts(root) end)
      }
    end
  end

  # Walk parent links up to the top-level root (guards against cycles/orphans by bounding the climb).
  defp climb_to_root(msg, by_id, fuel \\ 64)
  defp climb_to_root(msg, _by_id, 0), do: msg

  defp climb_to_root(msg, by_id, fuel) do
    case parent(msg) do
      p when p in [nil, ""] -> msg
      pid -> case Map.get(by_id, pid), do: (nil -> msg; up -> climb_to_root(up, by_id, fuel - 1))
    end
  end

  # ── reactions ──────────────────────────────────────────────────────────────────────────────────

  @doc """
  Aggregate reactions for one message: `[%{emoji:, count:, authors:}]`, most-reacted first. `authors`
  is de-duplicated (a user reacting twice with the same emoji counts once).
  """
  @spec reactions_for([map], term) :: [map]
  def reactions_for(reactions, message_id) do
    reactions
    |> Enum.filter(&(get(&1, :message) == message_id))
    |> Enum.group_by(&get(&1, :emoji))
    |> Enum.map(fn {emoji, rows} ->
      authors = rows |> Enum.map(&get(&1, :author)) |> Enum.uniq()
      %{emoji: emoji, count: length(authors), authors: authors}
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  # ── read cursors + unread ────────────────────────────────────────────────────────────────────────

  @doc "The last-read ts for `user` in `channel` from a list of cursor rows (0 if none)."
  @spec cursor_ts([map], term, term) :: integer
  def cursor_ts(cursors, channel, user) do
    cursors
    |> Enum.filter(&(get(&1, :channel) == channel and get(&1, :user) == user))
    |> Enum.map(&ts/1)
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Unread count for `user` in `channel`: messages newer than the user's read cursor, NOT authored by
  the user themself (your own messages don't ping you). Generic — the server computes this
  authoritatively rather than letting the client guess.
  """
  @spec unread([map], [map], term, term) :: non_neg_integer
  def unread(messages, cursors, channel, user) do
    last = cursor_ts(cursors, channel, user)

    messages
    |> Enum.filter(&(get(&1, :channel) == channel))
    |> Enum.filter(&(ts(&1) > last))
    |> Enum.reject(&(get(&1, :author) == user))
    |> length()
  end

  @doc """
  Whether `user` is @-mentioned in any unread message of `channel` (a stronger ping than mere unread).
  Looks for `@user` as a word in the body. Server-computed so badges are authoritative.
  """
  @spec mentioned?([map], [map], term, String.t()) :: boolean
  def mentioned?(messages, cursors, channel, user) when is_binary(user) do
    last = cursor_ts(cursors, channel, user)
    needle = "@" <> user

    messages
    |> Enum.filter(&(get(&1, :channel) == channel and ts(&1) > last))
    |> Enum.any?(fn m -> String.contains?(to_string(get(m, :body) || ""), needle) end)
  end
end
