defmodule Nexus.ChatTest do
  @moduledoc "Threads (parent), reaction aggregation, read cursors + unread/mention — pure logic."
  use ExUnit.Case, async: true

  # message rows as plain maps (what a decoded shape delta looks like)
  defp msg(id, channel, author, body, ts, parent \\ ""),
    do: %{id: id, channel: channel, author: author, body: body, ts: ts, parent: parent}

  describe "threads" do
    test "roots are parentless, oldest-first" do
      ms = [msg("b", "gen", "u", "second", 2), msg("a", "gen", "u", "first", 1), msg("r", "gen", "u", "reply", 3, "a")]
      assert Enum.map(Nexus.Chat.roots(ms), & &1.id) == ["a", "b"]
    end

    test "threads attach replies to their root, with counts + last_reply_ts" do
      ms = [
        msg("a", "gen", "u", "root", 1),
        msg("r1", "gen", "v", "reply one", 5, "a"),
        msg("r2", "gen", "w", "reply two", 9, "a"),
        msg("b", "gen", "u", "other root", 2)
      ]

      threads = Nexus.Chat.threads(ms)
      a = Enum.find(threads, &(&1.message.id == "a"))
      assert a.reply_count == 2
      assert a.last_reply_ts == 9
      assert Enum.map(a.replies, & &1.id) == ["r1", "r2"]
      assert Enum.find(threads, &(&1.message.id == "b")).reply_count == 0
    end

    test "a reply-to-a-reply files under the nearest root (single-level threads)" do
      ms = [msg("a", "gen", "u", "root", 1), msg("r1", "gen", "v", "reply", 5, "a"), msg("r2", "gen", "w", "nested", 7, "r1")]
      a = Nexus.Chat.threads(ms) |> Enum.find(&(&1.message.id == "a"))
      assert Enum.map(a.replies, & &1.id) == ["r1", "r2"]
    end
  end

  describe "reactions" do
    test "aggregates by emoji, dedupes authors, most-reacted first" do
      rs = [
        %{message: "m1", emoji: "👍", author: "a"},
        %{message: "m1", emoji: "👍", author: "b"},
        %{message: "m1", emoji: "👍", author: "a"},
        %{message: "m1", emoji: "🎉", author: "a"},
        %{message: "m2", emoji: "👍", author: "z"}
      ]

      agg = Nexus.Chat.reactions_for(rs, "m1")
      assert [%{emoji: "👍", count: 2, authors: authors}, %{emoji: "🎉", count: 1}] = agg
      assert Enum.sort(authors) == ["a", "b"]
    end
  end

  describe "unread + cursors" do
    setup do
      ms = [
        msg("a", "gen", "alice", "hi", 1),
        msg("b", "gen", "bob", "yo @alice", 5),
        msg("c", "gen", "bob", "later", 9),
        msg("d", "alice-dm", "bob", "elsewhere", 9)
      ]

      {:ok, ms: ms}
    end

    test "unread counts newer messages not authored by the user", %{ms: ms} do
      cursors = [%{channel: "gen", user: "alice", ts: 1}]
      # messages b(5) and c(9) are after cursor 1; both by bob → 2 unread for alice
      assert Nexus.Chat.unread(ms, cursors, "gen", "alice") == 2
      # bob has no cursor (0) but his own messages don't count; only alice's "hi"(1) → 1 unread for bob
      assert Nexus.Chat.unread(ms, [], "gen", "bob") == 1
    end

    test "your own messages never count as unread", %{ms: ms} do
      assert Nexus.Chat.unread(ms, [%{channel: "gen", user: "bob", ts: 0}], "gen", "bob") == 1
    end

    test "@-mention detection over unread messages", %{ms: ms} do
      assert Nexus.Chat.mentioned?(ms, [%{channel: "gen", user: "alice", ts: 1}], "gen", "alice")
      refute Nexus.Chat.mentioned?(ms, [%{channel: "gen", user: "bob", ts: 0}], "gen", "bob")
    end

    test "cursor_ts picks the latest cursor for a user/channel", %{ms: _ms} do
      cursors = [%{channel: "gen", user: "alice", ts: 3}, %{channel: "gen", user: "alice", ts: 8}]
      assert Nexus.Chat.cursor_ts(cursors, "gen", "alice") == 8
    end
  end
end
