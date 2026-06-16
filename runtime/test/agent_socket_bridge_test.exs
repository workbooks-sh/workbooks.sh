defmodule AgentSocketBridgeTest do
  @moduledoc """
  The PhoenixSocket bridge that turns AgentSession run messages
  (`{:agent_delta, chunk}` / `{:agent_done, result}` / …) into the channel frames
  the desktop renders (`llm_delta`, `llm_turn_stop`, `session_completed`, …).

  This is the second half of the #4 fix: the AUTH half (a `?token=` socket must
  resolve the run's real tenant) is locked in `auth_plug_test.exs`; here we lock
  the TRANSLATION + the no-joined-session drop, so a future refactor can't make
  the channel go silent again while the run completes underneath it.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PhoenixSocket, as: PS

  defp state(session \\ %{topic: "session:run-x", join_ref: "1", turn: false}) do
    %{tenant: "alice", topics: %{}, session: session}
  end

  # handle_info returns {:push, frame | [frame], state}; decode the Phoenix v2
  # frames ([join_ref, nil, topic, event, payload]) into {event, payload} pairs.
  defp pushed({:push, list, _st}) when is_list(list), do: Enum.map(list, &decode/1)
  defp pushed({:push, one, _st}), do: [decode(one)]
  defp decode({:text, json}), do: (d = Jason.decode!(json)) && {Enum.at(d, 3), Enum.at(d, 4)}

  test "agent_delta → llm_turn_start then llm_delta carrying the chunk; turn opens" do
    out = PS.handle_info({:agent_delta, "hello"}, state())
    frames = pushed(out)
    assert Enum.map(frames, &elem(&1, 0)) == ["llm_turn_start", "llm_delta"]

    {_ev, payload} = Enum.find(frames, &(elem(&1, 0) == "llm_delta"))
    assert payload["metadata"]["content"] == "hello"

    {:push, _, st} = out
    assert st.session.turn == true
  end

  test "a second agent_delta omits llm_turn_start (turn already open)" do
    out = PS.handle_info({:agent_delta, "more"}, state(%{topic: "session:run-x", join_ref: "1", turn: true}))
    assert Enum.map(pushed(out), &elem(&1, 0)) == ["llm_delta"]
  end

  test "agent_done → llm_turn_stop + session_completed with the authoritative text" do
    frames = pushed(PS.handle_info({:agent_done, "FINAL"}, state(%{topic: "session:run-x", join_ref: "1", turn: true})))
    assert Enum.map(frames, &elem(&1, 0)) == ["llm_turn_stop", "session_completed"]
    {_ev, stop_payload} = hd(frames)
    assert stop_payload["metadata"]["content"] == "FINAL"
    assert stop_payload["metadata"]["status"] == "ok"
  end

  test "bridge_session_started → a session_started frame" do
    frames = pushed(PS.handle_info({:bridge_session_started, "session:run-x", "1"}, state()))
    assert Enum.map(frames, &elem(&1, 0)) == ["session_started"]
  end

  # Adversarial: an agent event arriving on a socket that never joined a session
  # (no `:session` in state) must be a harmless no-op — never a crash, never a push
  # onto an unrelated topic.
  test "agent events with no joined session are dropped (no crash, no push)" do
    bare = %{tenant: "alice", topics: %{}}
    assert PS.handle_info({:agent_delta, "x"}, bare) == {:ok, bare}
    assert PS.handle_info({:agent_done, "x"}, bare) == {:ok, bare}
  end
end
