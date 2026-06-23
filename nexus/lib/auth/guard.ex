defmodule Nexus.Auth.Guard do
  @moduledoc """
  Per-route guards — the Guardian half of the native auth feature (RFC nexus/AUTH-ROUTING-RFC.md,
  epic wb-0uil). A workbook declares a policy:

      auth do
        protect "/admin/**", role: "admin"
        protect "POST /api/**", scope: "write"
        public  "/", "/pricing"
      end

  which compiles into a **guard table** the runtime checks on every request, after the auth adapter
  resolves identity. `Nexus.Auth.call/2` enforces the decision.

  ## Security model — fail-closed, backward-compatible

    * **No `auth` declared ⇒ `decide/3` ALWAYS allows** — existing deployments are byte-for-byte
      unchanged; adding this engine cannot lock anyone out or change behavior.
    * Once `auth` is declared the posture flips to **default-deny**: a request with no matching
      `public` rule requires (at least) authentication; `protect` rules add role/scope requirements.
    * Matching is **most-specific-wins** and **fail-closed**: an unmatched protected path denies; a
      malformed requirement is treated as the strictest (`:authenticated` + no role match → deny).

  The guard runs AFTER `authenticate/1`, so 401-for-no-identity is the adapter's job; the guard adds
  403-for-wrong-role/scope and the public/default-deny policy. Registered in `:persistent_term`
  (survives the bringup-compile process, like routes).
  """
  @reg {__MODULE__, :policy}

  @empty %{declared: false, guards: [], public: []}

  # ── declaration API (called at bringup from a parsed `auth` block) ──
  @doc "Mark that the workbook declared an `auth` policy — flips the posture to default-deny."
  def declare, do: put(%{state() | declared: true})

  @doc ~S'Add a guard: `protect("/admin/**", role: "admin")` or `protect("POST /api/**", scope: "x")`.'
  def protect(spec, opts \\ []) do
    {method, glob} = parse(spec)
    req = requirement(opts)
    s = state()
    put(%{s | declared: true, guards: [{method, segments(glob), req} | s.guards]})
  end

  @doc "Mark path glob(s) as public — no authentication required."
  def public(specs) do
    globs = specs |> List.wrap() |> Enum.map(fn s -> {elem(parse(s), 0), segments(elem(parse(s), 1))} end)
    s = state()
    put(%{s | declared: true, public: globs ++ s.public})
  end

  @doc """
  Load an `auth do … end` block AST (from a workbook) into the guard table. Registers `declare` +
  every `protect`/`public` statement. Unknown statements (provider/session — later phases) are ignored.
  """
  def load(ast) do
    declare()

    ast |> body() |> stmts() |> Enum.each(fn
      {:protect, _, [spec, opts]} when is_binary(spec) and is_list(opts) -> protect(spec, opts)
      {:protect, _, [spec]} when is_binary(spec) -> protect(spec, [])
      {:public, _, specs} -> public(Enum.filter(specs, &is_binary/1))
      _ -> :ok
    end)
  end

  defp body({:auth, _, args}) when is_list(args), do: Enum.find_value(args, fn [{:do, b}] -> b; _ -> nil end)
  defp body(_), do: nil
  defp stmts({:__block__, _, s}), do: s
  defp stmts(nil), do: []
  defp stmts(single), do: [single]

  @doc "Reset the policy (test seam / re-bringup)."
  def reset, do: put(@empty)

  @doc "Whether an `auth` policy has been declared at all."
  def declared?, do: state().declared

  # ── decision ──
  @doc """
  Decide a request given the resolved `identity` (post-authenticate):
  `:allow` | `:unauthenticated` (needs login) | `:forbidden` (lacks role/scope).
  """
  def decide(method, path, identity) do
    s = state()
    method = up(method)
    segs = segments(path)

    cond do
      not s.declared ->
        :allow

      true ->
        # MOST-SPECIFIC-WINS across BOTH public and protect (red-team wb-ma9v): previously `public` was
        # checked first and won unconditionally, so a broad `public "/api/**"` shadowed a narrow
        # `protect "POST /api/admin/**"`. Now every matching rule (public or protect) competes by
        # specificity; the most specific decides. Ties favor protect (fail-safe — enforce over expose).
        case most_specific(method, segs, s.public, s.guards) do
          :public -> :allow
          {:protect, req} -> enforce(req, identity)
          :none -> enforce(nil, identity)
        end
    end
  end

  # Rank every matching public/protect rule by specificity (lower = more specific); the winner decides.
  # On a specificity tie, protect sorts before public (kind 0 < 1) so a deny-capable rule wins.
  defp most_specific(method, segs, publics, guards) do
    pub =
      publics
      |> Enum.filter(fn {m, pat} -> (m == :any or m == method) and glob_match?(pat, segs) end)
      |> Enum.map(fn {_m, pat} -> {specificity(pat), 1, :public} end)

    prot =
      guards
      |> Enum.filter(fn {m, pat, _r} -> (m == :any or m == method) and glob_match?(pat, segs) end)
      |> Enum.map(fn {_m, pat, req} -> {specificity(pat), 0, {:protect, req}} end)

    case Enum.sort(pub ++ prot) do
      [{_spec, _kind, decision} | _] -> decision
      [] -> :none
    end
  end

  @doc "Whether a request path is declared public (Nexus.Auth unions this with its built-in public set)."
  def public?(method, path), do: public_match?(up(method), segments(path), state().public)

  # ── internals ──
  defp enforce(nil, identity), do: if(authenticated?(identity), do: :allow, else: :unauthenticated)
  defp enforce(:authenticated, identity), do: if(authenticated?(identity), do: :allow, else: :unauthenticated)
  # RANK-based (fix wb-i04g): a higher role satisfies a lower requirement (owner ⊇ admin ⊇ member ⊇
  # viewer), consistent with Nexus.Authz/role_at_least? — not exact-string membership.
  defp enforce({:role, r}, identity),
    do: if(authenticated?(identity) and Enum.any?(roles(identity), &Nexus.Auth.role_at_least?(&1, r)), do: :allow, else: deny(identity))
  defp enforce({:scope, sc}, identity), do: if(authenticated?(identity) and sc in scopes(identity), do: :allow, else: deny(identity))

  # Unauthenticated → needs login (401); authenticated but lacking the claim → forbidden (403).
  defp deny(identity), do: if(authenticated?(identity), do: :forbidden, else: :unauthenticated)

  defp authenticated?(%{tenant: t}) when is_binary(t) and t != "", do: true
  defp authenticated?(_), do: false
  defp roles(%{roles: rs}) when is_list(rs), do: rs
  defp roles(_), do: []
  defp scopes(%{scopes: ss}) when is_list(ss), do: ss
  defp scopes(_), do: []

  defp public_match?(method, segs, publics),
    do: Enum.any?(publics, fn {m, pat} -> (m == :any or m == method) and glob_match?(pat, segs) end)

  # lower = more specific: count "**" heavily, ":param" lightly; literals are free.
  defp specificity(pat), do: Enum.reduce(pat, 0, fn
    "**", a -> a + 100
    ":" <> _, a -> a + 1
    _lit, a -> a
  end)

  # glob: literal == literal; ":x" matches one segment; "**" matches zero-or-more remaining segments.
  defp glob_match?(["**"], _segs), do: true
  defp glob_match?(["**" | rest], segs) do
    Enum.any?(0..length(segs), fn n -> glob_match?(rest, Enum.drop(segs, n)) end)
  end
  defp glob_match?([":" <> _ | pr], [_ | sr]), do: glob_match?(pr, sr)
  defp glob_match?([lit | pr], [lit | sr]), do: glob_match?(pr, sr)
  defp glob_match?([], []), do: true
  defp glob_match?(_, _), do: false

  defp requirement(opts) do
    cond do
      r = opts[:role] -> {:role, to_string(r)}
      s = opts[:scope] -> {:scope, to_string(s)}
      true -> :authenticated
    end
  end

  @doc ~S'Parse `"METHOD /glob"` → `{"METHOD" | :any, "/glob"}` (no method ⇒ `:any`).'
  def parse(spec) do
    case String.split(String.trim(spec), ~r/\s+/, parts: 2) do
      [m, p] -> {up(m), norm(p)}
      [p] -> {:any, norm(p)}
    end
  end

  defp up(:any), do: :any
  defp up(m), do: m |> to_string() |> String.upcase()
  defp norm("/" <> _ = p), do: p
  defp norm(p), do: "/" <> p
  # Cap the segment count: glob_match?'s `**` clause recurses over `0..length(segs)`, so a deep
  # attacker-controlled path (run pre-auth in public?/decide) could amplify backtracking into a cheap
  # CPU-DoS (red-team wb-tcn9). No real route has more than a handful of segments, so we cap well above
  # that — a path exceeding the cap is truncated, which can't match a specific route and falls through to
  # the require-auth default (fail-safe), and bounds the `**` recursion to the cap.
  @max_segments 64
  defp segments(path) do
    path |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true) |> Enum.take(@max_segments)
  end

  defp state, do: :persistent_term.get(@reg, @empty)
  defp put(s), do: (:persistent_term.put(@reg, s); :ok)
end
