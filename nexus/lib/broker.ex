defmodule Nexus.Broker do
  @moduledoc """
  The single trust boundary that holds the platform's high-value credentials — the envelope **KEK**
  (`WB_ENV_MASTER_KEY`, which decrypts *every* org's secret store) and the org-wide **Fly infra token**
  (`FLY_API_TOKEN`, which can destroy/exec into every tenant's machine).

  ## Why this exists (red-team wb-qmp8 / wb-7zsr / wb-pj0x / wb-10lz kill-chain)

  These two credentials previously lived in the same multi-tenant BEAM process env where tenant `.work`
  and wasm guests run, reachable by `System.get_env/1` (and by any compile-time RCE). That is the link
  that turns a single RCE foothold into total cross-org compromise: RCE → read the KEK → decrypt all
  secrets → read the Fly token → own every machine.

  The Broker closes that link two ways:

  1. **Centralization** — it is the *only* module that reads the KEK / Fly token, holding them in its
     own process state. Envelope `seal/2` + `unseal/2` run the AES-256-GCM inside the Broker; the raw
     key is never returned to a caller. `Nexus.ControlPlane.Env` and `Nexus.Fly` become thin clients.
  2. **`lockdown/0`** — once a serving nexus has booted, the captured secrets are *deleted from the OS
     process env* (`System.delete_env/1`), so `System.get_env("WB_ENV_MASTER_KEY")` /
     `System.get_env("FLY_API_TOKEN")` return `nil` for everyone afterward — including a compile-time
     RCE. The values survive only inside this GenServer's state.

  Residual (tracked): a full separate-container broker is needed to stop in-BEAM *arbitrary-code* RCE
  from calling `Nexus.Broker` directly; within one BEAM, `lockdown/0` + centralization removes the
  `System.get_env` exfil vector and is the strongest portable boundary. See the seam-0.2 residual issue.
  """
  use GenServer

  @kek_var "WB_ENV_MASTER_KEY"
  @fly_var "FLY_API_TOKEN"

  # ── public API ───────────────────────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "AES-256-GCM seal using the held KEK. → {:ok, %{iv, ciphertext, tag}} | {:error, :no_master_key}."
  @spec seal(binary()) :: {:ok, %{iv: binary(), ciphertext: binary(), tag: binary()}} | {:error, :no_master_key}
  def seal(value) when is_binary(value) do
    case kek() do
      {:ok, key} ->
        iv = :crypto.strong_rand_bytes(12)
        {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, <<>>, true)
        {:ok, %{iv: iv, ciphertext: ct, tag: tag}}

      err ->
        err
    end
  end

  @doc "AES-256-GCM unseal using the held KEK. → {:ok, plaintext} | {:error, :decrypt_failed | :no_master_key}."
  @spec unseal(%{iv: binary(), ciphertext: binary(), tag: binary()}) ::
          {:ok, binary()} | {:error, :decrypt_failed | :no_master_key}
  def unseal(%{iv: iv, ciphertext: ct, tag: tag}) do
    case kek() do
      {:ok, key} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, <<>>, tag, false) do
          :error -> {:error, :decrypt_failed}
          value when is_binary(value) -> {:ok, value}
        end

      err ->
        err
    end
  end

  @doc "True if a valid 32-byte KEK is available."
  def has_master_key?, do: match?({:ok, _}, kek())

  @doc """
  The Fly infra token, for the trusted `Nexus.Fly` module only. `nil` if unset.

  (In-BEAM this is still callable by arbitrary code — the separate-container broker is the residual
  fix — but it is no longer in the process env, closing the `System.get_env` exfil path of wb-qmp8.)
  """
  @spec fly_token() :: String.t() | nil
  def fly_token, do: get("fly_token", @fly_var)

  @doc """
  Capture-and-scrub: pull the high-value secrets out of the OS process env and keep them only in the
  Broker's state. Idempotent. Called from application start on a serving nexus; NOT called in tests so
  the env stays available to tests that set it dynamically.
  """
  def lockdown do
    if alive?() do
      GenServer.call(__MODULE__, :lockdown)
    else
      :noop
    end
  end

  # ── server ───────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{kek: capture_kek(), fly_token: System.get_env(@fly_var), locked: false}}

  @impl true
  def handle_call(:lockdown, _from, state) do
    # values already captured in state at init; now remove them from the shared process env
    System.delete_env(@kek_var)
    System.delete_env(@fly_var)
    {:reply, :ok, %{state | locked: true}}
  end

  @impl true
  def handle_call({:get, kind}, _from, state), do: {:reply, Map.get(state, kind), state}

  # ── internals ────────────────────────────────────────────────────────────────────────────────

  defp alive?, do: is_pid(Process.whereis(__MODULE__))

  # 32-byte key from the base64 WB_ENV_MASTER_KEY. Captured into state at init; once locked down, env is
  # gone so state is the only source. Before lockdown (and in unstarted/test contexts) we still read env
  # so a key set after boot is honored. Fails closed on anything that isn't exactly 32 bytes.
  defp kek do
    raw = (alive?() && GenServer.call(__MODULE__, {:get, :kek})) || decode_kek(System.get_env(@kek_var))

    case raw do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :no_master_key}
    end
  end

  defp capture_kek, do: decode_kek(System.get_env(@kek_var))

  defp decode_kek(nil), do: nil

  defp decode_kek(raw) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, key} -> key
      :error -> nil
    end
  end

  defp get(kind, env_var) do
    cond do
      alive?() -> GenServer.call(__MODULE__, {:get, String.to_atom(kind)}) || System.get_env(env_var)
      true -> System.get_env(env_var)
    end
  end
end
