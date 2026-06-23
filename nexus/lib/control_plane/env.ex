defmodule Nexus.ControlPlane.Env do
  @moduledoc """
  Org+workspace-scoped, encrypted-at-rest env-var store — the backend behind the dashboard's
  Doppler-like team secret manager. Records live in `Nexus.ControlPlane` under `kind: :env`, keyed
  `{org, :env, id}`, so org isolation is INHERITED structurally (a foreign org's id is physically
  unreachable) — this module never re-checks ownership, it just goes through the registry.

  **Encryption (the point of this module):** the plaintext value is NEVER stored. Each value is
  sealed with AES-256-GCM (`:crypto.crypto_one_time_aead`) under a 32-byte master key from the
  `WB_ENV_MASTER_KEY` deploy secret (base64). A fresh 12-byte IV per value → encrypting the same
  value twice yields different ciphertext. We persist only `{iv, ciphertext, tag}` + the plaintext
  length (for "looks valid" affordances) and decrypt solely in `reveal/2`.

  **Fail-closed:** no master key → `{:error, :no_master_key}`; we never fall back to an ephemeral or
  derived key (that would lose data on restart and/or store effectively-unencrypted values). Routes
  turn this into a 503. Plaintext and the key are never logged.
  """
  alias Nexus.ControlPlane, as: CP

  @kind :env
  @scopes ~w(user workspace package nexus)
  @name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc "List an org's env records, optionally filtered to a workspace, as REDACTED views (no value)."
  def list(org, workspace_id \\ nil) when is_binary(org) do
    CP.list(org, @kind)
    |> filter_ws(workspace_id)
    |> Enum.map(&redacted/1)
  end

  defp filter_ws(recs, nil), do: recs
  defp filter_ws(recs, ws), do: Enum.filter(recs, &(&1[:workspace_id] == ws))

  @doc """
  Create an env var: validate, encrypt the value, store the sealed record. Returns the redacted view.
  `attrs` keys: `name`, `value`, `scope`, `workspace_id` (required for the workspace scope),
  `package_name`. `{:ok, redacted} | {:error, reason}`; `:no_master_key` ⇒ nothing is stored.
  """
  def create(org, attrs) when is_binary(org) do
    name = attrs[:name]
    value = attrs[:value]
    scope = attrs[:scope]
    ws = blank_to_nil(attrs[:workspace_id])

    with :ok <- validate(name, value, scope, ws),
         {:ok, sealed} <- seal(value) do
      id = "env_" <> rand()

      rec =
        Map.merge(sealed, %{
          name: name,
          scope: scope,
          workspace_id: ws,
          package_name: blank_to_nil(attrs[:package_name]),
          length: byte_size(value)
        })

      {:ok, rec} = CP.put(org, @kind, id, rec)
      {:ok, redacted(rec)}
    end
  end

  @doc """
  Resolve a `nexus`-scoped secret by NAME for `org` and decrypt it — the seam `Nexus.Secrets` reads
  so a value set in the dashboard actually reaches the runtime. `{:ok, value} | {:error, :not_found}`
  (or a crypto/`:no_master_key` error from `unseal`).
  """
  def value(org, name) when is_binary(org) and is_binary(name) do
    CP.list(org, @kind)
    |> Enum.find(fn r -> r[:scope] == "nexus" and r[:name] == name end)
    |> case do
      nil -> {:error, :not_found}
      rec -> unseal(rec)
    end
  end

  @doc "Decrypt and return the value for one org-scoped id. `{:ok, value} | {:error, reason}`."
  def reveal(org, id) when is_binary(org) do
    with {:ok, rec} <- CP.get(org, @kind, id) do
      unseal(rec)
    end
  end

  @doc """
  Update an env var's name and/or value (re-encrypting on a value change), scoped to `org`.
  `attrs` keys: `name`, `value`. Returns the redacted view. Cross-org ⇒ `:not_found`.
  """
  def update(org, id, attrs) when is_binary(org) do
    with {:ok, _rec} <- CP.get(org, @kind, id),
         {:ok, patch} <- update_patch(attrs) do
      {:ok, rec} = CP.update(org, @kind, id, patch)
      {:ok, redacted(rec)}
    end
  end

  # Build the patch — only touch name/value, validating each; value-change re-seals + updates length.
  defp update_patch(attrs) do
    name = attrs[:name]
    value = attrs[:value]

    cond do
      not is_nil(name) and not Regex.match?(@name_re, name) ->
        {:error, :bad_name}

      is_binary(value) ->
        case seal(value) do
          {:ok, sealed} ->
            {:ok, sealed |> maybe_put(:name, name) |> Map.put(:length, byte_size(value))}

          err ->
            err
        end

      true ->
        {:ok, maybe_put(%{}, :name, name)}
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  @doc "Delete an env var scoped to `org` (foreign-org delete is a no-op). Returns `:ok`."
  def delete(org, id) when is_binary(org), do: CP.delete(org, @kind, id)

  # ── validation ──────────────────────────────────────────────────────────────────────────────
  defp validate(name, value, scope, ws) do
    cond do
      not is_binary(name) or name == "" -> {:error, :name_required}
      not Regex.match?(@name_re, name) -> {:error, :bad_name}
      not is_binary(value) -> {:error, :value_required}
      scope not in @scopes -> {:error, :bad_scope}
      scope == "workspace" and is_nil(ws) -> {:error, :workspace_required}
      true -> :ok
    end
  end

  # ── crypto (AES-256-GCM) ─────────────────────────────────────────────────────────────────────
  # The KEK lives ONLY in Nexus.Broker (the credential trust boundary) — this module never reads the
  # raw `WB_ENV_MASTER_KEY`. seal/unseal delegate to the Broker, which holds the key in its own process
  # state (and scrubs it from the OS env after boot). Still fail-closed: no key → {:error, :no_master_key}.
  defp seal(value) when is_binary(value), do: Nexus.Broker.seal(value)
  defp unseal(%{iv: _, ciphertext: _, tag: _} = rec), do: Nexus.Broker.unseal(rec)

  # ── views / helpers ──────────────────────────────────────────────────────────────────────────
  # Redacted view: never includes iv/ciphertext/tag or the plaintext — just a fixed 8-bullet mask.
  # The EXACT plaintext length is deliberately NOT exposed: a precise byte count is a credential-format
  # fingerprinting oracle (distinguishing a 40-char token from a 64-char key). We surface only a boolean
  # `present` so the UI can still show "set / not set" without the oracle. (red-team wb-cfk7)
  defp redacted(rec) do
    %{
      id: rec.id,
      name: rec[:name],
      scope: rec[:scope],
      workspace_id: rec[:workspace_id],
      package_name: rec[:package_name],
      masked: "••••••••",
      present: (rec[:length] || 0) > 0,
      created_at: rec[:created_at]
    }
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  defp rand, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
