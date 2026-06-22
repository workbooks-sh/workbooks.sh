defmodule Nexus.Authorship do
  @moduledoc """
  Author identity — one person, many device keys. The surface-agnostic core of slice 2 (epic wb-kodp).

  A person has ONE identity but signs from many surfaces — browser (WebCrypto/IndexedDB), CLI / editor /
  Claude Code (a key in the OS keychain, bound to the `wbk_` PAT), and nexus-side agents (a provisioned
  key). Each surface holds its own **device key**; all are registered under the user, so an edit from any
  surface is provably theirs. This is the Radicle device-key model: device keys under one identity.

  Registration is proof-of-possession, stateless: from an authenticated session/PAT (which fixes the
  `uid`), the client signs a canonical message binding `uid` + its `did`. The server verifies the
  signature against the DID's own public key — proving the client holds the private half — then records
  `uid → did`. No secret is ever handed out, so there's nothing to replay-steal.

  Verified authorship = a contribution's `author` DID is one of that user's registered, non-revoked
  device keys. THE LINE: keys + proofs are generic mechanism; the dashboard reading them is our cloud.

  ## The single chokepoint

  Every contribution — from any entry point — converges at the nexus commit boundary, because the nexus
  IS a git remote: CLI/editor/local arrive as a `git push` (receive hook), browser/dashboard edits as a
  cloud commit call, agents commit in-process. So enforcement lives in ONE place, server-side, not
  scattered across surfaces (which would each be a thing to forget or bypass). Edge surfaces *sign*; the
  nexus *verifies* — every time. Each ingress computes `verified?` its own way (cloud API →
  `verify_contribution/6`; git → `git verify-commit` + `verified_author?/2`) and then routes through the
  SAME `decide/2`, so the policy ladder can't drift between entry points:

    * `:off`  — no checks.
    * `:soft` — verify + record the flag; never reject (safe, non-breaking default).
    * `:hard` — reject any contribution not signed by a registered device key.
  """

  alias Nexus.Keyring

  @doc "The canonical message a device signs to register its key under `uid`."
  @spec registration_message(String.t(), String.t()) :: String.t()
  def registration_message(uid, did) when is_binary(uid) and is_binary(did),
    do:
      "wb-author-key\nuid=" <> Nexus.Canon.escape(String.downcase(uid)) <>
        "\ndid=" <> Nexus.Canon.escape(did)

  @doc """
  Verify a registration proof: the holder of `did`'s private key signed `registration_message(uid, did)`.
  `sig` is lower-case hex. Returns `true` only if the signature checks out against the DID's public key.
  """
  @spec verify_registration(String.t(), String.t(), String.t()) :: boolean()
  def verify_registration(uid, did, sig) when is_binary(uid) and is_binary(did) and is_binary(sig) do
    with {:ok, pub} <- Keyring.public_from_did(did),
         {:ok, raw} <- Base.decode16(sig, case: :lower) do
      Keyring.verify(pub, registration_message(uid, did), raw)
    else
      _ -> false
    end
  end

  def verify_registration(_, _, _), do: false

  @doc """
  Is `author_did` a verified author for this user — i.e. one of their registered, non-revoked device
  keys? `device_keys` is a list of maps with `:did` and (optional) `:revoked` truthiness.
  """
  @spec verified_author?(String.t() | nil, [map()]) :: boolean()
  def verified_author?(author_did, device_keys)
      when is_binary(author_did) and author_did != "" and is_list(device_keys) do
    Enum.any?(device_keys, fn k ->
      to_string(Map.get(k, :did)) == author_did and not truthy(Map.get(k, :revoked))
    end)
  end

  def verified_author?(_, _), do: false

  defp truthy(nil), do: false
  defp truthy(0), do: false
  defp truthy(false), do: false
  defp truthy(""), do: false
  defp truthy(_), do: true

  @doc """
  Does a contribution's `author` field belong to `uid`? EXACT equality only (fix wb-nw7e) — the old
  loose match (email local-part, or the literal `"me"`) let one user claim another's work. Blank/nil → false.
  """
  @spec mine?(term(), term()) :: boolean()
  def mine?(author, uid)
      when is_binary(author) and is_binary(uid) and author != "" and uid != "",
      do: author == uid

  def mine?(_, _), do: false

  @doc """
  Fold an append-only device-key event log to the currently-LIVE keys. A `:revoke` is TERMINAL for a did
  (fix wb-9mid): once any revoke event exists for a did, it is gone for good — a later `:register` can't
  resurrect it. Events: `%{did:, op: :register | :revoke, ts:}` (ts µs). Returns `[%{did:, registered:}]`
  (revoked dids absent), sorted by `registered` for deterministic output.
  """
  @spec fold_device_keys([map()]) :: [map()]
  def fold_device_keys(events) when is_list(events) do
    revoked = for %{op: :revoke, did: d} <- events, into: MapSet.new(), do: d

    events
    |> Enum.filter(&(&1[:op] == :register and not MapSet.member?(revoked, &1[:did])))
    |> Enum.group_by(& &1[:did])
    |> Enum.map(fn {did, evs} -> %{did: did, registered: evs |> Enum.map(& &1[:ts]) |> Enum.max()} end)
    |> Enum.sort_by(& &1.registered)
  end

  # ── the contribution gate (cloud-API ingress) ───────────────────────────────────────────────────

  @doc """
  The ONE chokepoint the cloud commit path calls before writing a contribution (fix wb-i2c8). Hashes the
  bytes, verifies the author proof carried in `req` (`%{author: %{uid, did, sig}, device_keys: [...]}`)
  via `verify_contribution/6`, then routes the result through `decide/2` with the active policy:

    * `{:accept, did}`           — verified: caller commits with `author = did`.
    * `{:accept_unverified, ""}` — soft/off + unverified: caller commits with `author = ""`.
    * `{:reject, reason}`        — hard + unverified: caller returns 403, no commit.
  """
  @spec gate_contribution(map(), String.t(), iodata()) ::
          {:accept, String.t()} | {:accept_unverified, String.t()} | {:reject, atom()}
  def gate_contribution(req, target, bytes) do
    a = req[:author] || %{}
    keys = req[:device_keys] || []
    verified? = verify_contribution(a[:uid], a[:did], a[:sig], target, content_hash(bytes), keys)

    case decide(verified?, Nexus.Config.authorship_policy()) do
      :reject -> {:reject, :unverified}
      # decide says allow — but only record an author DID when the proof actually verified; an allowed-
      # but-unverified commit (off/soft) is authorless, never credited to the claimed (unproven) did.
      _allow when verified? -> {:accept, a[:did]}
      _allow -> {:accept_unverified, ""}
    end
  end

  @doc """
  The canonical message a device signs to authorize one contribution: it binds the author (`uid`+`did`)
  to exactly what is being committed (`target` path + `content_hash`), so a signature can't be lifted
  onto a different edit. Used by the cloud commit path; the git-push path uses commit signatures instead.
  """
  @spec contribution_message(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def contribution_message(uid, did, target, content_hash) do
    e = &Nexus.Canon.escape/1

    "wb-contribution\nuid=" <> e.(String.downcase(to_string(uid))) <>
      "\ndid=" <> e.(did) <> "\ntarget=" <> e.(target) <>
      "\nhash=" <> e.(content_hash)
  end

  @doc """
  Verify a cloud-API contribution: the holder of `did`'s key signed `contribution_message/4` AND `did`
  is one of the user's registered, non-revoked device keys. `sig` is lower-case hex.
  """
  @spec verify_contribution(String.t(), String.t(), String.t(), String.t(), String.t(), [map()]) :: boolean()
  def verify_contribution(uid, did, sig, target, content_hash, device_keys) do
    verified_author?(did, device_keys) and
      (with {:ok, pub} <- Keyring.public_from_did(did),
            {:ok, raw} <- Base.decode16(to_string(sig), case: :lower) do
         Keyring.verify(pub, contribution_message(uid, did, target, content_hash), raw)
       else
         _ -> false
       end)
  end

  @doc "Hash a contribution's bytes — the `content_hash` half of the signed message (sha-256 hex)."
  @spec content_hash(iodata()) :: String.t()
  def content_hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  The ONE policy decision every ingress routes through — given whether the contribution verified and the
  active `policy`, return the verdict so the gate behaves identically at every entry point:

    * `:accept`            — verified (or policy `:off`): commit + record verified.
    * `:accept_unverified` — `:soft` + unverified: commit, but mark it unverified.
    * `:reject`            — `:hard` + unverified: refuse the commit.
  """
  @spec decide(boolean(), :off | :soft | :hard) :: :accept | :accept_unverified | :reject
  def decide(true, _policy), do: :accept
  def decide(false, :off), do: :accept
  def decide(false, :soft), do: :accept_unverified
  def decide(false, :hard), do: :reject
end
