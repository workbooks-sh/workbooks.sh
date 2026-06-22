defmodule Nexus.Ledger do
  @moduledoc """
  The ownership ledger — runtime-counter-signed metering, anchored to commits as git notes.

  When an agent run produces a commit, the runtime signs a metering attestation (tokens, model, cost,
  agent, who) with its own key (`Nexus.Attest`) and stores it as a note (`refs/notes/wb-meter`) keyed
  by that commit's hash (`Nexus.Git`). The commit hash anchors *what* was done (the content-addressed
  snapshot); the runtime signature anchors *how much* — and because the author never holds the runtime
  key, those numbers can't be inflated. Reading back, every record carries a `verified?` flag.

  The analytics (`profile_activity`) read this ledger to render the heatmap with a verified/unverified
  split. THE LINE: notes + signatures are generic git mechanism; the dashboard that aggregates them is
  our cloud.
  """

  alias Nexus.{Attest, Git, Keyring, Paths, Secrets}

  @ref "wb-meter"

  @doc "The nexus runtime signing key — from the `NEXUS_SIGNING_KEY` secret if set, else a durable on-disk key."
  @spec runtime_key() :: Keyring.keypair()
  def runtime_key do
    case Secrets.get("NEXUS_SIGNING_KEY") do
      hex when is_binary(hex) and byte_size(hex) >= 64 ->
        Keyring.from_private(Base.decode16!(String.trim(hex), case: :lower))

      _ ->
        Keyring.load_or_create(Path.join(Paths.durable_dir(), "nexus-signing.key"))
    end
  end

  @doc "This nexus's runtime `did:key` — publishable so anyone can verify our counter-signatures."
  @spec runtime_did() :: String.t()
  def runtime_did, do: runtime_key().public |> Keyring.did()

  @doc """
  Sign `fields` with `keypair` (default: the runtime key) and attach them as a meter note on `sha`
  in `repo` (a working tree or bare repo). Returns `{:ok, attestation}` or `{:error, reason}`.
  """
  @spec write_meter(Path.t(), String.t(), map(), Keyring.keypair() | nil) ::
          {:ok, Attest.t()} | {:error, term()}
  def write_meter(repo, sha, fields, keypair \\ nil) do
    att = Attest.sign(keypair || runtime_key(), fields)

    case Git.add_note(repo, sha, encode(att), @ref) do
      :ok -> {:ok, att}
      err -> err
    end
  end

  @doc """
  The PINNED trust anchor for verifying meter notes (fix wb-8hax): an explicit DID wins, else the
  published `Nexus.Config.ledger_did/0`. `nil` when a deploy hasn't pinned one — and a nil anchor makes
  every record read UNVERIFIED (fail closed), never "trust the live key".
  """
  @spec expected_did(String.t() | nil) :: String.t() | nil
  def expected_did(explicit \\ nil), do: explicit || safe_config_did()

  defp safe_config_did do
    Nexus.Config.ledger_did()
  rescue
    _ -> nil
  end

  @doc """
  Read every meter attestation in `repo`, each as `{commit_sha, attestation, verified?}`. A record is
  `verified?` ONLY if signed by exactly the pinned anchor (`expected_did/1`) — a forged note, or any
  note on a deploy with no pinned anchor, reads as unverified (fail closed, not fail open).
  """
  @spec read_meters(Path.t(), String.t() | nil) :: [{String.t(), Attest.t(), boolean()}]
  def read_meters(repo, expected_did \\ nil) do
    anchor = expected_did(expected_did)

    Git.notes(repo, @ref)
    |> Enum.map(fn {commit, body} ->
      att = decode(body)
      {commit, att, Attest.verify(att, anchor)}
    end)
  end

  # ── note wire-format ── (NOT a config/state surface: a signed record at the git-object boundary)
  # @did/@sig header lines, then the canonical signed field lines — round-trips through Attest.verify.
  @doc false
  def encode(%{did: did, sig: sig, fields: fields}) do
    "@did " <> did <> "\n@sig " <> sig <> "\n" <> Attest.preimage(fields)
  end

  @doc false
  def decode(text) when is_binary(text) do
    {meta, body} =
      text |> String.split("\n") |> Enum.split_with(&String.starts_with?(&1, "@"))

    # The body is a Nexus.Canon kv block — unescape it back to the exact signed field map (round-trips
    # Attest.preimage, so a value containing \n/= survives instead of being silently re-split).
    fields = body |> Enum.join("\n") |> Nexus.Canon.parse_kv()

    %{did: header(meta, "@did "), sig: header(meta, "@sig "), fields: fields}
  end

  defp header(lines, prefix) do
    Enum.find_value(lines, fn l ->
      if String.starts_with?(l, prefix),
        do: binary_part(l, byte_size(prefix), byte_size(l) - byte_size(prefix))
    end)
  end
end
