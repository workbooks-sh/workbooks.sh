defmodule Nexus.AuthorshipFixesTest do
  @moduledoc """
  RED tests for the pure authorship helpers the "server" lane fixes introduce/repair.

  Covered bugs + post-fix contracts:

  * wb-9mid (no-raise): `verify_registration/3` and `verify_contribution/6` must return
    `false` (not raise) when the `did` is malformed — today they call `Keyring.public_from_did/1`,
    which raises on a non-base58 did because `Keyring.base58_decode/1` is non-total.

  * wb-9mid (terminal revoke): a NEW pure helper the device-key handler will fold over —

        Nexus.Authorship.fold_device_keys(events :: [map]) :: [map]

    where each event is `%{did:, op: :register | :revoke, ts: integer}` (ts in os_time(:microsecond)).
    Semantics: a revoke is TERMINAL for a did — once revoked, that did is gone for good even if a
    later `:register` event arrives (today the handler `group_by did |> max_by(:registered)` so a
    re-register after revoke RESURRECTS the key — the bug). Output: the list of currently-live keys
    (`%{did:, registered: ts}`), revoked dids ABSENT. Microsecond ts makes ordering deterministic.

  * wb-nw7e (exact uid equality): a NEW pure helper

        Nexus.Authorship.mine?(author :: term, uid :: term) :: boolean

    matching ONLY on exact uid equality — today server.work `mine?/2` also matches the email
    local-part or the literal "me", which lets one user claim another's contributions.

  * verified_author? over fold output: a did re-registered AFTER a revoke is NOT a verified author.
  """
  use ExUnit.Case, async: true
  alias Nexus.{Authorship, Keyring}

  # ── wb-9mid: verify_* total over a malformed did (no raise) ──────────────────────────────────

  test "verify_registration/3 returns false (no raise) on a malformed did" do
    # 'l'/'0' are not base58 — public_from_did must thread :error, verify must be false not crash.
    refute Authorship.verify_registration("u@x", "did:key:z0OIl", "deadbeef")
    refute Authorship.verify_registration("u@x", "not-a-did", "deadbeef")
  end

  test "verify_contribution/6 returns false (no raise) on a malformed did" do
    keys = [%{did: "did:key:z0OIl", revoked: 0}]

    refute Authorship.verify_contribution(
             "u@x",
             "did:key:z0OIl",
             "deadbeef",
             "site/index.work",
             "abc123",
             keys
           )
  end

  # ── wb-9mid: fold_device_keys — revoke is TERMINAL ───────────────────────────────────────────

  test "fold_device_keys/1: a never-revoked did survives" do
    live = Authorship.fold_device_keys([%{did: "did:a", op: :register, ts: 1}])
    assert Enum.map(live, & &1.did) == ["did:a"]
  end

  test "fold_device_keys/1: revoke is terminal — [register, revoke, register] leaves the did ABSENT" do
    for events <- [
          # chronological re-register after revoke must NOT resurrect
          [
            %{did: "did:a", op: :register, ts: 1},
            %{did: "did:a", op: :revoke, ts: 2},
            %{did: "did:a", op: :register, ts: 3}
          ],
          # even if the stray register event is presented LAST in any order, revoke wins
          [
            %{did: "did:a", op: :register, ts: 3},
            %{did: "did:a", op: :register, ts: 1},
            %{did: "did:a", op: :revoke, ts: 2}
          ]
        ] do
      live = Authorship.fold_device_keys(events)
      refute "did:a" in Enum.map(live, & &1.did)
    end
  end

  test "fold_device_keys/1: mixed dids — revoked absent, live present, deterministic" do
    events = [
      %{did: "did:live", op: :register, ts: 10},
      %{did: "did:dead", op: :register, ts: 11},
      %{did: "did:dead", op: :revoke, ts: 12},
      %{did: "did:dead", op: :register, ts: 13}
    ]

    live_dids = Authorship.fold_device_keys(events) |> Enum.map(& &1.did)
    assert "did:live" in live_dids
    refute "did:dead" in live_dids
  end

  test "verified_author? over fold output: a re-registered-after-revoke did is NOT verified" do
    events = [
      %{did: "did:a", op: :register, ts: 1},
      %{did: "did:a", op: :revoke, ts: 2},
      %{did: "did:a", op: :register, ts: 3}
    ]

    live = Authorship.fold_device_keys(events)
    refute Authorship.verified_author?("did:a", live)
  end

  # ── wb-nw7e: mine?/2 is EXACT uid equality only ──────────────────────────────────────────────

  test "mine?/2 is true only on exact uid equality" do
    assert Authorship.mine?("alice@example.com", "alice@example.com")
  end

  test "mine?/2 rejects email local-part, the literal \"me\", and nil/empty (no loose matching)" do
    refute Authorship.mine?("alice", "alice@example.com")
    refute Authorship.mine?("me", "alice@example.com")
    refute Authorship.mine?(nil, "alice@example.com")
    refute Authorship.mine?("", "alice@example.com")
    refute Authorship.mine?("bob@example.com", "alice@example.com")
  end
end
