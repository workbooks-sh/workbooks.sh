defmodule Workbooks.AutopoetTest do
  use ExUnit.Case, async: false

  alias Workbooks.Autopoet
  alias Workbooks.Autopoet.Worker

  setup do
    dir = Path.join(System.tmp_dir!(), "ap-test-#{System.unique_integer([:positive])}")
    prev = System.get_env("WB_DATA")
    System.put_env("WB_DATA", dir)
    on_exit(fn ->
      File.rm_rf(dir)
      if prev, do: System.put_env("WB_DATA", prev), else: System.delete_env("WB_DATA")
    end)
    :ok
  end

  describe "the backlog (file_issue / list / status)" do
    test "files an issue and lists it open" do
      {:ok, id} = Autopoet.file_issue(%{title: "need a slugify tool", need: "slug", tenant: "lander"})
      assert [%{id: ^id, status: :open, kind: :capability, title: "need a slugify tool"}] = Autopoet.list(:open)
    end

    test "the agent's file_issue TOOL wiring maps args → backlog + returns a filed message" do
      # The self-editing seam: an agent calling its file_issue tool must land a
      # real backlog entry (exec_one maps title/need/tenant → Autopoet.file_issue).
      {out, _st} =
        Workbooks.Agent.__exec_one_for_test__(
          %{name: "file_issue", args: %{"title" => "need a foobar tool", "need" => "foobar"}},
          %{tenant: "lander"}
        )

      assert out =~ "issue filed"
      assert [%{title: "need a foobar tool", status: :open}] = Autopoet.list(:open)
    end

    test "an empty title is rejected" do
      assert {:error, :no_title} = Autopoet.file_issue(%{title: "  "})
    end

    test "duplicate (title,tenant) collapses and bumps seen, not re-filed" do
      {:ok, id} = Autopoet.file_issue(%{title: "dup", tenant: "lander"})
      {:ok, id2} = Autopoet.file_issue(%{title: "dup", tenant: "lander"})
      assert id == id2
      assert [%{seen: 2}] = Autopoet.list(:open)
      # a different tenant is a distinct issue
      {:ok, id3} = Autopoet.file_issue(%{title: "dup", tenant: "bitml"})
      refute id3 == id
      assert length(Autopoet.list(:open)) == 2
    end

    test "set_status transitions and rekind_host reclassifies" do
      {:ok, id} = Autopoet.file_issue(%{title: "x", tenant: "t"})
      :ok = Autopoet.set_status(id, :doing, "picked up")
      assert [%{status: :doing}] = Autopoet.list()
      :ok = Autopoet.set_status(id, :done, "shipped")
      assert Autopoet.list(:open) == []
      assert [%{status: :done}] = Autopoet.list(:done)

      {:ok, id2} = Autopoet.file_issue(%{title: "needs primitive", tenant: "t"})
      :ok = Autopoet.rekind_host(id2)
      assert Enum.find(Autopoet.list(), &(&1.id == id2)).kind == :host
    end
  end

  describe "the worker's verdict classification (pure)" do
    test "DONE on the first line closes" do
      assert {:done, _} = Worker.classify("DONE: authored the seo toolkit, wb toolkit verify passed")
    end

    test "HOST routes to the human lane" do
      assert {:host, _} = Worker.classify("HOST: needs an http HEAD primitive the config layer can't express")
    end

    test "anything else stays open for a retry" do
      assert {:open, _} = Worker.classify("I got partway but ran out of steps")
      assert {:open, _} = Worker.classify("")
    end

    test "the first line decides — DONE beats a later HOST mention" do
      assert {:done, _} = Worker.classify("DONE: built it.\nFootnote: a HOST primitive could improve it later")
    end
  end
end
