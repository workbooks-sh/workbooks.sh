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
  Read every meter attestation in `repo`, each as `{commit_sha, attestation, verified?}`. When
  `expected_did` is given (e.g. our published runtime DID), a record is `verified?` only if signed by
  exactly that key — so a forged note from an unknown key reads as unverified.
  """
  @spec read_meters(Path.t(), String.t() | nil) :: [{String.t(), Attest.t(), boolean()}]
  def read_meters(repo, expected_did \\ nil) do
    Git.notes(repo, @ref)
    |> Enum.map(fn {commit, body} ->
      att = decode(body)
      {commit, att, Attest.verify(att, expected_did)}
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

    fields =
      body
      |> Enum.reject(&(&1 == ""))
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)

    %{did: header(meta, "@did "), sig: header(meta, "@sig "), fields: fields}
  end

  defp header(lines, prefix) do
    Enum.find_value(lines, fn l ->
      if String.starts_with?(l, prefix),
        do: binary_part(l, byte_size(prefix), byte_size(l) - byte_size(prefix))
    end)
  end
end
