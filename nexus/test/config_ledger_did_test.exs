defmodule Nexus.ConfigLedgerDidTest do
  @moduledoc """
  RED tests for the pinned trust-anchor config getter (wb-8hax).

  There is no `Nexus.Config.ledger_did/0` today — the runtime trust anchor defaults to the LIVE running
  key (`Ledger.runtime_did/0`), which an attacker-run nexus can mint and self-trust. Post-fix, the
  pinned/published DID is a `.work` deploy-block attr `ledger-did="did:key:z…"` read via Nexus.Config,
  with a neutral default of nil (NO-JSON rule: config home, not an env read).

  Helper the implementer must provide (named exactly as the spec proposes):
    * Nexus.Config.ledger_did/0 :: String.t() | nil  (parse-map entry: ledger_did: attr(html, "ledger-did"))
  """
  use ExUnit.Case
  alias Nexus.Config

  test "neutral default is nil when no deploy block / no ledger-did attr" do
    Config.reload(nil)
    assert Config.ledger_did() == nil
  end

  test "reads a pinned ledger-did from the deploy block" do
    src = """
    deploy do
      ledger-did="did:key:zPinnedAnchor123"
    end
    """

    Config.reload(src)
    assert Config.ledger_did() == "did:key:zPinnedAnchor123"
  end

  test "absent attr in a present deploy block is nil (not a crash, not a default DID)" do
    src = """
    deploy do
      auth="trusted"
    end
    """

    Config.reload(src)
    assert Config.ledger_did() == nil
  end
end
