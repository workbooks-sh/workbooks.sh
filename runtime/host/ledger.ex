defmodule Workbooks.Ledger do
  @moduledoc """
  The signed agent ledger (Phase 2g) — the hardening that turns the always-on
  telemetry into tamper-EVIDENT + ATTRIBUTABLE provenance.

  Phase 0 gave us `_steps.jsonl`: every tool call, always logged. That's the raw
  record but it's editable — nothing stops a rewrite after the fact. `seal/2`
  closes that:

    * HASH-CHAIN (tamper-evident): each step's hash folds in the prior hash, so
      `h_i = sha256(h_{i-1} || raw_line_i)`. Chaining the RAW bytes of the log
      (not a re-encode) means altering, inserting, or dropping ANY line changes
      the head — `verify/1` recomputes and catches it.
    * SIGN (attributable): the head is signed by the tenant's Ed25519 did:key
      (`Workbooks.Git`). Whoever holds the run is bound to a DID; neither agent
      nor user can forge a head for a key they don't hold.
    * ANCHOR (externally verifiable): the head is handed to a carrier (a git/JJ
      commit now; an ATproto record later) so the record is witnessed OUTSIDE the
      workdir. `anchor/2` does the git half; the sharing phase adds the rest.

  Same file the telemetry already writes — the ledger is a seal OVER it, not a
  second log. See docs/IDENTITY-GIT-MONOREPO.org "The signed agent ledger".
  """
  alias Workbooks.Git

  @genesis "workbooks-ledger-v1"

  @doc """
  Seal a run's `_steps.jsonl` into `_ledger.json`: hash-chain the raw lines, sign
  the head with the tenant's did:key. Returns the ledger map. Best-effort.
  """
  def seal(workdir, tenant) do
    lines = raw_lines(workdir)
    head = Enum.reduce(lines, hash(@genesis), fn line, prev -> hash(prev <> line) end)
    sig = Git.sign(tenant, head) |> Base.encode16(case: :lower)

    led = %{v: 1, did: Git.did(tenant), count: length(lines), head: head, sig: sig,
            ts: System.system_time(:second)}

    File.write!(Path.join(workdir, "_ledger.json"), Jason.encode!(led))
    led
  rescue
    e -> %{error: Exception.message(e)}
  end

  @doc """
  Verify a sealed run: recompute the chain over the CURRENT `_steps.jsonl` and
  check the signature. `tamper_evident` = the log still matches the sealed head
  (count + chain); `attributable` = the head is signed by the recorded DID.
  Both true ⇒ the record is intact and provably from that agent.
  """
  def verify(workdir) do
    case File.read(Path.join(workdir, "_ledger.json")) do
      {:ok, body} ->
        led = Jason.decode!(body)
        lines = raw_lines(workdir)
        head = Enum.reduce(lines, hash(@genesis), fn line, prev -> hash(prev <> line) end)

        tamper_evident = head == led["head"] and length(lines) == led["count"]
        sig_ok = sig_ok?(led, head)

        %{tamper_evident: tamper_evident, attributable: tamper_evident and sig_ok,
          did: led["did"], count: led["count"], head: led["head"]}

      _ -> %{error: "no ledger for this run"}
    end
  rescue
    e -> %{error: Exception.message(e)}
  end

  @doc """
  Anchor the sealed head to a carrier (externally verifiable). Now: commit
  `_ledger.json` into the tenant repo so the head is witnessed by git's own
  content-addressing. Later (sharing phase): also emit an ATproto record / JJ op.
  Returns the carrier commit sha or `:nochange`.
  """
  def anchor(workdir, tenant) do
    src = Path.join(workdir, "_ledger.json")
    if File.exists?(src) do
      Git.save(%{tenant: tenant, author: "agent-ledger", email: "ledger@workbooks"},
               "ledger-" <> Path.basename(workdir), File.read!(src))
    else
      :nochange
    end
  end

  defp sig_ok?(led, head) do
    Git.verify_sig(led["did"], head, Base.decode16!(led["sig"], case: :lower))
  rescue
    _ -> false
  end

  defp raw_lines(workdir) do
    case File.read(Path.join(workdir, "_steps.jsonl")) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  defp hash(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)
end
