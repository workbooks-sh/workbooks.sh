defmodule Workbooks.Access do
  @moduledoc """
  Access POSTURE — the per-workbook/route security stance, and the one place that
  decides what a caller may see (wb-9io; RUNTIME-CONNECT-PROTOCOL.md "Routing &
  access posture"). Routing is coupled to auth: a route's posture + the caller's
  identity decide the answer. Three postures:

    * `:public`      — fully public. The whole workbook may be baked into a static,
                       self-contained artifact (single HTML). No secrets. Anyone.
    * `:gated_data`  — the SHELL is public (no secrets), but the DATA/capabilities
                       are fetched from the runtime per-request, behind auth. The
                       "app behind the page" is the runtime, not the file.
    * `:gated_route` — even the shell/existence is private; the runtime serves it
                       ONLY to an authenticated caller.

  CRITICAL INVARIANT (the anti-leak rule): a `gated_*` workbook must NEVER be
  rendered into a public static artifact — a static file ships its contents to
  anyone with the URL, so client-side gating is theater. `static_safe?/1` is the
  guard the publish pipeline enforces. Desktop (local trust) is exempt — it ships
  only a SHELL that fetches data over RCP, never inlines server-side secrets.
  """

  @postures [:public, :gated_data, :gated_route]

  @doc "Parse a posture string (`public` | `gated-data` | `gated-route`). Default `:public`."
  def parse(nil), do: {:ok, :public}
  def parse(""), do: {:ok, :public}

  def parse(s) when is_binary(s) do
    case s |> String.trim() |> String.downcase() |> String.replace("_", "-") do
      "public" -> {:ok, :public}
      "gated-data" -> {:ok, :gated_data}
      "gated-route" -> {:ok, :gated_route}
      other -> {:error, "unknown access posture #{inspect(other)} (public | gated-data | gated-route)"}
    end
  end

  def parse(posture) when posture in @postures, do: {:ok, posture}

  @doc "The known postures."
  def postures, do: @postures

  @doc """
  Can a workbook of this posture be safely baked into a PUBLIC STATIC artifact
  (a single self-contained HTML on a dumb host)? Only `:public` — anything gated
  would leak its inlined contents. This is the publish anti-leak guard.
  """
  def static_safe?(:public), do: true
  def static_safe?(p) when p in @postures, do: false

  @doc """
  The serving decision: given a posture, what the caller DEMANDS (`:shell` — the
  app/structure, `:data` — protected content/capabilities, `:full` — both
  inlined), and the resolved identity (`nil` = anonymous), return `:allow` or
  `{:deny, reason}`.

    public      → always allow
    gated_data  → shell is public; data/full require an identity
    gated_route → everything requires an identity (even the shell)
  """
  def enforce(:public, _demand, _identity), do: :allow

  def enforce(:gated_data, demand, identity) do
    cond do
      demand == :shell -> :allow
      authed?(identity) -> :allow
      true -> {:deny, :auth_required}
    end
  end

  def enforce(:gated_route, _demand, identity) do
    if authed?(identity), do: :allow, else: {:deny, :auth_required}
  end

  @doc """
  Resolve a workbook's declared posture. Pluggable: a `:posture` in the workbook's
  registered metadata wins; otherwise `:public` (fail-OPEN is wrong for security,
  but unregistered workbooks carry no server-side secrets to leak — they ARE their
  static selves; a workbook becomes gated only by explicitly declaring it).
  """
  def posture_for(meta) when is_map(meta) do
    case meta[:posture] || meta["posture"] do
      nil -> :public
      p -> with {:ok, parsed} <- parse(p), do: parsed, else: (_ -> :public)
    end
  end

  def posture_for(_), do: :public

  # An identity counts as authenticated when it names a real user/tenant — NOT the
  # anonymous dev fallback (user_id "dev").
  defp authed?(nil), do: false
  defp authed?(%{user_id: uid}) when is_binary(uid) and uid not in ["dev", ""], do: true
  defp authed?(_), do: false
end
