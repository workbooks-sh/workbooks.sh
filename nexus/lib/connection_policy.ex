defmodule Nexus.ConnectionPolicy do
  @moduledoc """
  Per-connection permission gating — the *generic* enforcement seam behind the dashboard's
  "connection details" page.

  A connection (an `:integration` record in `Nexus.ControlPlane`) can carry an `allowed` list:
  the subset of its **grant keys** a tenant has left enabled. A grant key is an opaque string —
  the runtime attaches **no** provider meaning to it. The dashboard supplies the catalog that maps
  a provider's real surface onto grant keys:

    * **CLI-backed** connection → a grant key is a command group (`gws gmail` → `"gmail"`). The
      `host_exec` seam maps `argv` to a grant key via `argv_grant/2` and refuses a blocked one.
    * **API-backed** connection → a grant key is an OAuth scope / endpoint group (`"repo"`). The
      token-handout seam (`Cloud.Integrations.fresh_token/3`) checks `allowed?/3` before revealing.

  Semantics, deliberately fail-open on *absence* and fail-closed on *restriction*:

    * `allowed` absent (a brand-new or never-restricted connection) → **every** grant is allowed.
      Connecting an account grants its full surface until the tenant narrows it; we never silently
      withhold a capability the user believes they connected.
    * `allowed` present (a list, possibly empty) → **only** the listed keys are allowed. An empty
      list is a fully-restricted connection (nothing passes), which is a legitimate "paused" state.

  This module is pure mechanism: it stores and answers the allow-list. It is config-driven and
  carries none of our (or any deployer's) provider catalog — that lives in the app on top of it.
  """

  alias Nexus.ControlPlane, as: CP

  @kind :integration

  @doc """
  Is `grant_key` permitted on connection `id` for `tenant`?

  `true` when the connection has no `allowed` list (unrestricted) or the key is in it; `false`
  when an `allowed` list is present and the key is absent. A missing connection is `false`
  (you cannot exercise a grant on a connection that does not exist).
  """
  def allowed?(tenant, id, grant_key) when is_binary(grant_key) do
    case CP.get(tenant, @kind, id) do
      {:ok, rec} -> allowed_in?(rec, grant_key)
      _ -> false
    end
  end

  @doc "The effective allow-list for a record: its stored list, or `:all` when unrestricted."
  def allowed_list(rec) do
    case rec[:allowed] do
      list when is_list(list) -> list
      _ -> :all
    end
  end

  defp allowed_in?(rec, grant_key) do
    case allowed_list(rec) do
      :all -> true
      list -> grant_key in list
    end
  end

  @doc """
  Set the allow-list on connection `id`. `keys` is restricted to `valid_keys` (the connection's
  real grant surface, supplied by the app) so a stale/forged key can never widen access. Pass
  `valid_keys: :all` to skip the intersection (the caller already validated). Returns
  `{:ok, allowed_keys} | {:error, reason}`.
  """
  def set(tenant, id, keys, opts \\ []) when is_list(keys) do
    valid = Keyword.get(opts, :valid_keys, :all)

    allowed =
      case valid do
        :all -> Enum.uniq(keys)
        list when is_list(list) -> Enum.filter(Enum.uniq(keys), &(&1 in list))
      end

    case CP.update(tenant, @kind, id, %{allowed: allowed}) do
      {:ok, _rec} -> {:ok, allowed}
      err -> err
    end
  end

  @doc "Clear all restriction — restore the connection to its full granted surface."
  def clear(tenant, id) do
    case CP.update(tenant, @kind, id, %{allowed: nil}) do
      {:ok, _rec} -> :ok
      err -> err
    end
  end

  @doc """
  Map a CLI invocation to the grant key it exercises, using the connection's `command_grants`
  map (command-group string → grant key, e.g. `%{"gmail" => "gmail"}`). `argv` is the parsed
  command (`["gws", "gmail", "+send", ...]`). The CLI binary itself is `argv` head; the command
  group is the first non-flag token after it. Returns the grant key, or `nil` when the argv does
  not name a known group (an unmapped command falls through to the seam's default policy).
  """
  def argv_grant(command_grants, argv) when is_map(command_grants) and is_list(argv) do
    argv
    |> Enum.drop(1)
    |> Enum.find(fn tok -> not String.starts_with?(tok, "-") end)
    |> case do
      nil -> nil
      group -> command_grants[group]
    end
  end
end
