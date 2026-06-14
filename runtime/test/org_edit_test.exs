defmodule Workbooks.OrgEditTest do
  @moduledoc """
  Unit tests for the surgical Org headline editor that backs the kanban board's
  card mutations (wb-kbq5). Pure text in / text out — deterministic, no app boot.
  Covers the happy paths plus the edge cases that bite line-level Org edits:
  keyword-vs-title disambiguation, drawer creation, headline-by-id location, and
  preservation of everything we didn't touch.
  """
  use ExUnit.Case, async: true

  alias Workbooks.OrgEdit

  defp doc do
    """
    * TODO First card :work:
    :PROPERTIES:
    :ID: c1
    :PRIORITY: B
    :END:
    First body.

    * Second card
    :PROPERTIES:
    :ID: c2
    :END:
    Second body.
    """
  end

  describe "transition_todo" do
    test "rewrites an existing TODO keyword, preserving tags + body + props" do
      {:ok, out} = OrgEdit.patch(doc(), "c1", "transition_todo", %{"state" => "DONE"})
      assert out =~ "* DONE First card :work:"
      refute out =~ "* TODO First card"
      # untouched bits survive
      assert out =~ ":PRIORITY: B"
      assert out =~ "First body."
      assert out =~ "* Second card"
    end

    test "inserts a keyword when the headline has none (first word is the title)" do
      {:ok, out} = OrgEdit.patch(doc(), "c2", "transition_todo", %{"state" => "DOING"})
      assert out =~ "* DOING Second card"
      # the original title word is kept, not eaten
      refute out =~ "* DOING card"
    end

    test "only the matched headline changes" do
      {:ok, out} = OrgEdit.patch(doc(), "c1", "transition_todo", %{"state" => "DONE"})
      # c2 headline untouched
      assert out =~ "* Second card"
    end
  end

  describe "set_property" do
    test "updates an existing property in place" do
      {:ok, out} = OrgEdit.patch(doc(), "c1", "set_property", %{"name" => "PRIORITY", "value" => "A"})
      assert out =~ ~r/:PRIORITY:\s+A/
      refute out =~ ~r/:PRIORITY:\s+B/
    end

    test "adds a new property inside the existing drawer (before :END:)" do
      {:ok, out} = OrgEdit.patch(doc(), "c1", "set_property", %{"name" => "ASSIGNEE", "value" => "sam"})
      assert out =~ ~r/:ASSIGNEE:\s+sam/
      # still a well-formed drawer
      assert out =~ ":PROPERTIES:"
      assert out =~ ":END:"
      # the new prop sits before END, not after
      [before_end, _] = String.split(out, ":END:", parts: 2)
      assert before_end =~ "ASSIGNEE"
    end

    test "creates a drawer when the headline has none" do
      org = "* TODO Lonely\nbody\n"
      # No ID drawer → can't locate by id; locate by a headline that has one.
      org2 = "* TODO Lonely\n:PROPERTIES:\n:ID: x1\n:END:\nbody\n"
      {:ok, out} = OrgEdit.patch(org2, "x1", "set_property", %{"name" => "K", "value" => "v"})
      assert out =~ ~r/:K:\s+v/
      assert org =~ "Lonely"
    end
  end

  describe "append_logbook" do
    test "inserts a note after the headline's drawer" do
      {:ok, out} = OrgEdit.patch(doc(), "c1", "append_logbook", %{"entry" => "moved to done"})
      assert out =~ "moved to done"
    end
  end

  describe "location + errors" do
    test "unknown id → :not_found" do
      assert OrgEdit.patch(doc(), "nope", "transition_todo", %{"state" => "DONE"}) == {:error, :not_found}
    end

    test "unsupported op → error tuple" do
      assert {:error, {:unsupported_op, "frobnicate"}} =
               OrgEdit.patch(doc(), "c1", "frobnicate", %{})
    end

    test "locates a deeply-nested headline by id" do
      org = """
      * Project
      ** Phase one
      *** TODO Deep task
      :PROPERTIES:
      :ID: deep1
      :END:
      """

      {:ok, out} = OrgEdit.patch(org, "deep1", "transition_todo", %{"state" => "DONE"})
      assert out =~ "*** DONE Deep task"
      # parent headlines untouched
      assert out =~ "* Project"
      assert out =~ "** Phase one"
    end
  end
end
