defmodule Workbooks.PublicWebActivityTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @moduledoc """
  /_activity shapes (wb-wc0.2). Hermetic — no LLM (no worker is running in the
  test, so `status[:running]` is falsey and Thoughts never fires). Covers:

    * LEGACY single-agent shape when no crew (`{agent, steps, thought}`) — the
      lander frontend reads this unchanged.
    * CREW shape when WB_CREW_DEF is set (`{agents, wire, agent}`), each agent
      carrying name/running/lifecycle/steps/thought, plus a merged `wire` and a
      backward-compat `agent` block.
  """

  setup do
    case Workbooks.Domains.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    prev_crew = System.get_env("WB_CREW_DEF")

    on_exit(fn ->
      if prev_crew, do: System.put_env("WB_CREW_DEF", prev_crew), else: System.delete_env("WB_CREW_DEF")
    end)

    :ok
  end

  defp activity(host) do
    conn =
      conn(:get, "/_activity")
      |> Map.put(:host, host)
      |> Workbooks.PublicWeb.call([])

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  describe "legacy single-agent shape (no crew)" do
    test "returns {agent, steps, thought} — the lander shape, untouched" do
      System.delete_env("WB_CREW_DEF")
      body = activity("dev.apps.example")

      assert Map.has_key?(body, "agent")
      assert Map.has_key?(body, "steps")
      assert Map.has_key?(body, "thought")
      assert is_list(body["steps"])
      # crew-only keys absent
      refute Map.has_key?(body, "agents")
      refute Map.has_key?(body, "wire")
    end
  end

  describe "crew shape (WB_CREW_DEF set)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "wb_act_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      manifest = Path.join(tmp, "crew.org")

      File.write!(manifest, """
      #+TITLE: crew
      * wren
      :PROPERTIES:
      :DEF: /data/agents/writer.org
      :INTERVAL: 10m
      :END:
      * moss
      :PROPERTIES:
      :DEF: /data/agents/editor.org
      :END:
      """)

      System.put_env("WB_CREW_DEF", manifest)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{tmp: tmp}
    end

    test "returns {agents, wire, agent} with one entry per declared agent" do
      body = activity("dev.apps.example")

      assert is_list(body["agents"])
      assert Enum.map(body["agents"], & &1["name"]) == ["wren", "moss"]

      for a <- body["agents"] do
        assert Map.has_key?(a, "name")
        assert Map.has_key?(a, "running")
        assert Map.has_key?(a, "lifecycle")
        assert is_list(a["steps"])
        assert Map.has_key?(a, "thought")
      end

      # merged wire + backward-compat legacy `agent` block both present.
      assert is_list(body["wire"])
      assert Map.has_key?(body, "agent")
    end
  end
end
