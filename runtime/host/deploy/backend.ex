defmodule Workbooks.Deploy.Backend do
  @moduledoc """
  The deploy-kit's provider seam — `place` → backend, plug-and-play. Mirrors the
  storage seam (`Workbooks.Backend`): the core depends on a contract, a provider
  fills it, selection is one config value (`place`). Two kinds:

    * `local` — built-in, the krunvm microVM (`Workbooks.Deploy.Krunvm`).
    * a CLOUD PROVIDER — a recipe toolkit at `deploy/providers/<place>/bootstrap.sh`
      that sources the neutral spine (`deploy/providers/_recipe.sh`) and fills the
      five hooks (ensure_app / set_secrets / attach_volume / deploy_image /
      public_url). Adding a provider = drop a directory; the core never changes.

  In the simplified model there is no ephemeral-sandbox half (one BEAM container,
  WASM inside), so a provider only implements the ENGINE contract — "run my
  container + volume + secrets + port" — which ports cleanly to any PaaS / host.
  """

  @doc "The providers directory (deploy/providers, found by walking up from CWD)."
  def providers_dir do
    Enum.reduce_while(0..12, File.cwd!(), fn _, dir ->
      p = Path.join([dir, "deploy", "providers"])

      cond do
        File.dir?(p) -> {:halt, p}
        dir in ["/", "."] -> {:halt, nil}
        true -> {:cont, Path.dirname(dir)}
      end
    end)
  end

  @doc "All available places — `local` plus every discovered cloud provider."
  def list do
    cloud =
      case providers_dir() do
        nil -> []
        dir -> Path.join(dir, "*/bootstrap.sh") |> Path.wildcard() |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      end

    ["local" | Enum.sort(cloud)]
  end

  @doc "Resolve a place to a backend: {:local, mod} | {:provider, place, bootstrap} | {:error, msg}."
  def resolve("local"), do: {:local, Workbooks.Deploy.Krunvm}

  def resolve(place) do
    case providers_dir() do
      nil ->
        {:error, "no deploy/providers directory found"}

      dir ->
        boot = Path.join([dir, place, "bootstrap.sh"])
        if File.exists?(boot), do: {:provider, place, boot}, else: {:error, "unknown place '#{place}' — available: #{Enum.join(list(), ", ")}"}
    end
  end

  @doc """
  Run a provider recipe action (`up` | `down` | `status` | `logs`) for a cloud
  `place`, passing the assembled env. Streams the provider's combined output and
  returns {:ok, out} | {:error, out}. The provider's own exit code is honored
  (non-zero → {:error}), so the AX exit-code contract reaches all the way down.
  """
  def run_provider(boot, action, env) do
    full_env =
      env
      |> Map.put("WB_RECIPE_ACTION", action)
      |> Map.put("WB_PROVIDERS_DIR", Path.dirname(Path.dirname(boot)))
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    {out, code} = System.cmd("bash", [boot], env: full_env, stderr_to_stdout: true)
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
