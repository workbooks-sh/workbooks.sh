defmodule Workbooks.AgentSessionTest do
  @moduledoc """
  The AgentSession not-found contract: every call against an UNKNOWN session id
  returns :not_found (never raises / hangs). The desktop polls GET /api/run/:id,
  the WS cancel + CTK review/commit, and the run-status reads all depend on this —
  a gone or never-existed session must degrade cleanly. Deterministic (just the
  Registry miss; no agent run / LLM).
  """
  use ExUnit.Case, async: true

  alias Workbooks.AgentSession

  test "status/subscribe/cancel/take_review/put_review for an unknown id → :not_found" do
    id = "run-nope-#{System.unique_integer([:positive])}"

    assert AgentSession.status(id) == :not_found
    assert AgentSession.subscribe(id) == :not_found
    assert AgentSession.cancel(id) == :not_found
    assert AgentSession.take_review(id) == :not_found
    assert AgentSession.put_review(id, %{"approved" => true}) == :not_found
  end
end
